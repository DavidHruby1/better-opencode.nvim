local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local Promise = require("opencode.promise")

---Creates an on-disk source buffer so the tests exercise Neovim's file and window boundary.
---The caller owns cleanup because some cases deliberately add windows, marks, or write hooks.
---@param lines string[]
---@param filetype string
---@return string, integer, integer
local function source_buffer(lines, filetype)
  local path = vim.fn.tempname() .. ".lua"
  vim.fn.writefile(lines, path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.bo[buf].filetype = filetype
  return path, buf, win
end

---Waits for a plugin Promise without sleeping for an arbitrary time.
---The returned pair keeps rejection visible to the test instead of turning a failed behavior into a timeout.
---@param promise Promise<any>
---@return any, any
local function await(promise)
  local value, err
  promise
    :next(function(result)
      value = result
    end)
    :catch(function(reason)
      err = reason
    end)
  eq(
    vim.wait(1000, function()
      return value ~= nil or err ~= nil
    end),
    true
  )
  return value, err
end

---Builds the smallest ready Runtime accepted by prompt dispatch.
---Its HTTP client returns controlled OpenCode-shaped responses while buffer, scope, session, and prompt code stay real.
---@param root string
---@param calls table
---@param session_id string
---@return table
local function ready_runtime(root, calls, session_id)
  local sessions = require("opencode.session")
  local runtime = {
    root = root,
    root_hash = vim.fn.sha256(root),
    state = "ready",
    sse_live = true,
    prompt_locked = false,
    interaction_locked = false,
    reconciling = false,
    sessions = {},
    jobs = {},
    sidebar = {
      visible = false,
      show = function()
        table.insert(calls.order, "split")
        runtime.sidebar.visible = true
        calls.sidebar_shown = true
        return true
      end,
      is_visible = function()
        return runtime.sidebar.visible
      end,
      select_session = function(_, id)
        table.insert(calls.order, "select")
        calls.selects = calls.selects + 1
        table.insert(calls.selected, id)
        return Promise.resolve(nil)
      end,
    },
    selected_session_id = nil,
  }
  ---Returns one owned Session detail with the exact permission suffix expected before reuse.
  ---The fake keeps the network outside the test while preserving the metadata and directory checks in Session code.
  local function detail(id)
    return {
      id = id,
      directory = root,
      title = "Session " .. id,
      metadata = sessions.metadata(runtime.root_hash),
      permission = vim.deepcopy(sessions.permissions),
    }
  end
  runtime.client = {
    create_session = function(_, payload)
      calls.creates = calls.creates + 1
      calls.create_payload = payload
      table.insert(calls.create_payloads, payload)
      return Promise.resolve(detail(session_id))
    end,
    update_session = function(_, id, payload)
      calls.updates = calls.updates + 1
      calls.update_id, calls.update_payload = id, payload
      return Promise.resolve({})
    end,
    get_session = function(_, id)
      calls.gets = calls.gets + 1
      calls.get_id = id
      return Promise.resolve(detail(id))
    end,
    select_session = function(_, id)
      calls.selects = calls.selects + 1
      table.insert(calls.selected, id)
      return Promise.resolve({})
    end,
    prompt_async = function(_, id, payload)
      table.insert(calls.order, "prompt")
      calls.prompt_session = id
      table.insert(calls.prompts, payload)
      return Promise.resolve({})
    end,
  }
  ---Reports the same readiness gate used by the public prompt dispatcher.
  ---The fake leaves state flags mutable so each test can still exercise the real gate checks.
  function runtime:accepts_prompts()
    return self.state == "ready"
      and self.sse_live
      and not self.prompt_locked
      and not self.interaction_locked
      and not self.reconciling
  end
  return runtime
end

---Creates call storage shared by the fake HTTP boundary and keeps assertions about dispatch explicit.
---@return table
local function calls()
  return {
    creates = 0,
    create_payloads = {},
    updates = 0,
    gets = 0,
    selects = 0,
    selected = {},
    prompts = {},
    order = {},
  }
end

---Fakes tmux only at the process boundary and gives every pane a deterministic ID/PID pair.
---The caller can replace or remove the live identity to prove revalidation without touching a real tmux server.
---@param callback fun(state: table)
local function with_tmux(callback)
  local old_system, old_executable = vim.system, vim.fn.executable
  local old_tmux, old_tmux_pane = vim.env.TMUX, vim.env.TMUX_PANE
  local old_ownership = package.loaded["opencode.runtime.ownership"]
  local state = {
    pane_id = "%pane-1",
    pane_pid = 7001,
    pane_live = false,
    calls = {},
  }
  local function completed(code, stdout)
    return {
      code = code,
      stdout = stdout or "",
      stderr = "",
      wait = function(self)
        return self
      end,
    }
  end
  vim.env.TMUX, vim.env.TMUX_PANE = "session-1", "%source"
  vim.fn.executable = function(name)
    return name == "tmux" and 1 or old_executable(name)
  end
  package.loaded["opencode.runtime.ownership"] = {
    identity = function(pid)
      return { pid = pid, start = "start-" .. pid, executable = "/fake/opencode" }
    end,
    write = function() end,
  }
  vim.system = function(command, opts)
    table.insert(state.calls, { command = vim.deepcopy(command), opts = opts })
    local action = command[2]
    if action == "display-message" then
      if not state.pane_live then
        return completed(1)
      end
      return completed(0, state.pane_id .. "\t" .. state.pane_pid)
    end
    if action == "split-window" then
      state.pane_live = true
      return completed(0, state.pane_id .. "\t" .. state.pane_pid)
    end
    if action == "kill-pane" then
      state.pane_live = false
      return completed(0)
    end
    return completed(0)
  end
  local ok, err = xpcall(function()
    callback(state)
  end, debug.traceback)
  vim.system, vim.fn.executable = old_system, old_executable
  vim.env.TMUX, vim.env.TMUX_PANE = old_tmux, old_tmux_pane
  package.loaded["opencode.runtime.ownership"] = old_ownership
  assert(ok, err)
end

---Replaces only the Snacks window constructor so ask tests still exercise the real editor callbacks and Promise flow.
---The fake owns a real scratch buffer, giving multiline text and close/focus behavior the same observable boundary as a float.
---@param callback fun(captured: table, window: table)
local function with_prompt_window(callback)
  local old_win, old_lsp, old_notify = package.loaded["snacks.win"], vim.lsp.start, vim.notify
  local captured, fake = {}, {}
  vim.lsp.start = function() end
  vim.notify = function() end
  package.loaded["snacks.win"] = function(opts)
    for key, value in pairs(opts) do
      captured[key] = value
    end
    local buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.text or "", "\n", { plain = true }))
    vim.api.nvim_set_current_buf(buf)
    local opened = {
      buf = buf,
      win = vim.api.nvim_get_current_win(),
      opts = opts,
      valid = function(self)
        return self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf)
      end,
      text = function(self)
        return table.concat(vim.api.nvim_buf_get_lines(self.buf, 0, -1, false), "\n")
      end,
      update = function(self)
        for key, value in pairs(self.opts) do
          captured[key] = value
        end
      end,
      close = function(self)
        if self.buf then
          opts.on_close(self)
          vim.api.nvim_buf_delete(self.buf, { force = true })
          self.buf = nil
        end
      end,
    }
    for key, value in pairs(opened) do
      fake[key] = value
    end
    for _, key in ipairs({ "newline", "newline_fallback", "submit" }) do
      local mapping = opts.keys[key]
      vim.keymap.set("i", mapping[1], function()
        return mapping[2]()
      end, { buffer = buf, expr = mapping.expr == true })
    end
    opts.on_buf(fake)
    opts.on_win(fake)
    return fake
  end
  local ok, err = xpcall(function()
    callback(captured, fake)
  end, debug.traceback)
  package.loaded["snacks.win"] = old_win
  vim.lsp.start, vim.notify = old_lsp, old_notify
  if fake and fake.buf and vim.api.nvim_buf_is_valid(fake.buf) then
    vim.api.nvim_buf_delete(fake.buf, { force = true })
  end
  assert(ok, err)
end

T["AC-UI-01 inline prompt shows Build root function scope and restores source focus"] = function()
  local path, buf, source_win = source_buffer({ "local function alpha()", "  return 1", "end" }, "lua")
  vim.api.nvim_win_set_cursor(source_win, { 2, 2 })
  local capture = assert(require("opencode.context").capture())
  local context = require("opencode.context").new(capture, { root = vim.fs.dirname(path) })
  with_prompt_window(function(captured, fake)
    local result = require("opencode.ui.ask").ask(nil, context, "build")
    captured.keys.submit_normal[2]()
    eq(await(result), "")
    eq(captured.title:find("Build", 1, true) ~= nil, true)
    eq(captured.title:find(vim.fs.dirname(path), 1, true) ~= nil, true)
    eq(captured.title:find("function", 1, true) ~= nil, true)
    eq(fake:text(), "")
  end)
  eq(vim.api.nvim_get_current_win(), source_win)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["multiline Enter queues unchanged text until Runtime readiness resolves"] = function()
  local path, buf, source_win = source_buffer({ "source" }, "text")
  local context =
    require("opencode.context").new(assert(require("opencode.context").capture()), { root = vim.fs.dirname(path) })
  local readiness, resolve = Promise.with_resolvers()
  local submitted
  local initial = "first line\nsecond line"
  with_prompt_window(function(captured, fake)
    local result = require("opencode.ui.ask").ask(initial, context, "build", nil, readiness, function(text)
      submitted = text
      return Promise.resolve(nil)
    end)
    captured.keys.submit[2]()
    eq(
      vim.wait(50, function()
        return submitted ~= nil
      end),
      false
    )
    eq(fake:text(), initial)
    resolve(true)
    eq(
      vim.wait(500, function()
        return submitted ~= nil
      end),
      true
    )
    eq(submitted, initial)
    local value = await(result)
    eq(value, initial)
  end)
  eq(vim.api.nvim_get_current_win(), source_win)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["startup or dispatch failure keeps multiline input available for retry"] = function()
  local path, buf = source_buffer({ "source" }, "text")
  local context =
    require("opencode.context").new(assert(require("opencode.context").capture()), { root = vim.fs.dirname(path) })
  local readiness = Promise.reject({ error_class = "startup_timeout" })
  local attempts, submitted = 0, {}
  local initial = "keep this\nand this"
  with_prompt_window(function(captured, fake)
    local result = require("opencode.ui.ask").ask(initial, context, "plan", nil, readiness, function(text)
      attempts = attempts + 1
      table.insert(submitted, text)
      return attempts == 1 and Promise.reject({ error_class = "prompt_http" }) or Promise.resolve(nil)
    end)
    eq(
      vim.wait(500, function()
        return captured.footer ~= nil
      end),
      true
    )
    eq(fake:text(), initial)
    captured.keys.submit[2]()
    eq(
      vim.wait(500, function()
        return attempts == 1
      end),
      true
    )
    eq(fake:text(), initial)
    captured.keys.submit[2]()
    local value = await(result)
    eq(value, initial)
    eq(submitted, { initial, initial })
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["multiline editor mappings create real lines and visible completion is accepted"] = function()
  local path, buf = source_buffer({ "source" }, "text")
  local context =
    require("opencode.context").new(assert(require("opencode.context").capture()), { root = vim.fs.dirname(path) })
  local old_pumvisible = vim.fn.pumvisible
  local submitted = 0
  with_prompt_window(function(captured, fake)
    local result = require("opencode.ui.ask").ask("first", context, "plan", nil, nil, function()
      submitted = submitted + 1
      return Promise.resolve(nil)
    end)
    captured.keys.newline[2]()
    captured.keys.newline_fallback[2]()
    eq(vim.api.nvim_buf_get_lines(fake.buf, 0, -1, false), { "first", "", "" })
    vim.fn.pumvisible = function()
      return 1
    end
    eq(captured.keys.submit[2](), "<C-y>")
    eq(submitted, 0)
    vim.fn.pumvisible = old_pumvisible
    captured.keys.submit_normal[2]()
    eq(await(result), "first\n\n")
  end)
  vim.fn.pumvisible = old_pumvisible
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["prompt title follows the selected Build or Plan mode"] = function()
  local path, buf = source_buffer({ "source" }, "text")
  local context =
    require("opencode.context").new(assert(require("opencode.context").capture()), { root = vim.fs.dirname(path) })
  for _, mode in ipairs({ "build", "plan" }) do
    with_prompt_window(function(captured)
      local result = require("opencode.ui.ask").ask(nil, context, mode)
      local expected = mode:gsub("^%l", string.upper)
      eq(captured.title:match("^" .. expected), expected)
      captured.keys.cancel[2]()
      eq(select(2, await(result)).error_class, "cancelled")
    end)
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["prompt geometry stays visible at an edge and grows with multiline input"] = function()
  local path, buf, source_win = source_buffer({ "edge", "edge", "edge" }, "text")
  vim.api.nvim_win_set_cursor(source_win, { 3, 4 })
  local capture = assert(require("opencode.context").capture())
  local context = require("opencode.context").new(capture, { root = vim.fs.dirname(path) })
  with_prompt_window(function(captured, fake)
    local result = require("opencode.ui.ask").ask("one\ntwo", context, "plan")
    local lines = math.max(vim.o.lines - vim.o.cmdheight, 1)
    eq(captured.row >= 0, true)
    eq(captured.col >= 0, true)
    eq(captured.row + captured.height + 2 <= lines, true)
    eq(captured.col + captured.width + 2 <= vim.o.columns, true)
    local old_height = captured.height
    vim.api.nvim_buf_set_lines(fake.buf, 0, -1, false, { "1", "2", "3", "4", "5", "6", "7", "8" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = fake.buf })
    eq(captured.height > old_height, true)
    captured.keys.cancel[2]()
    local _, error = await(result)
    eq(error.error_class, "cancelled")
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["AC-UI-02 sidebar lazily splits the active root and leaves focus detached"] = function()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  with_tmux(function(state)
    local runtime = { root = root, client = { url = "http://127.0.0.1:1" }, username = "u", password = "p" }
    local source_win = vim.api.nvim_get_current_win()
    local sidebar = assert(require("opencode.ui.sidebar").new(runtime))
    runtime.sidebar = sidebar
    local Runtime = require("opencode.runtime")
    Runtime.registry[root] = runtime
    eq(Runtime.show_root(root), runtime)
    eq(sidebar:is_visible(), true)
    eq(vim.api.nvim_get_current_win(), source_win)
    eq(state.calls[1].command, {
      "tmux",
      "split-window",
      "-h",
      "-d",
      "-p",
      "30",
      "-t",
      "%source",
      "-P",
      "-F",
      "#{pane_id}\t#{pane_pid}",
      "-e",
      "OPENCODE_SERVER_USERNAME=u",
      "-e",
      "OPENCODE_SERVER_PASSWORD=p",
      "opencode",
      "attach",
      "http://127.0.0.1:1",
      "--dir",
      root,
    })
    eq(state.calls[1].opts.cwd, root)
    eq(state.calls[2].command, { "tmux", "select-pane", "-d", "-t", "%pane-1" })
    sidebar:show_root(runtime)
    eq(#state.calls, 4)
    eq(state.calls[4].command, { "tmux", "display-message", "-p", "-t", "%pane-1", "#{pane_id}\t#{pane_pid}" })

    sidebar:focus()
    eq(state.calls[5].command, { "tmux", "display-message", "-p", "-t", "%pane-1", "#{pane_id}\t#{pane_pid}" })
    eq(state.calls[6].command, { "tmux", "display-message", "-p", "-t", "%pane-1", "#{pane_id}\t#{pane_pid}" })
    eq(state.calls[7].command, { "tmux", "select-pane", "-t", "%pane-1" })
    sidebar:toggle()
    eq(state.calls[8].command, { "tmux", "display-message", "-p", "-t", "%pane-1", "#{pane_id}\t#{pane_pid}" })
    eq(state.calls[9].command, { "tmux", "display-message", "-p", "-t", "%pane-1", "#{pane_id}\t#{pane_pid}" })
    eq(state.calls[10].command, { "tmux", "kill-pane", "-t", "%pane-1" })
    eq(sidebar:is_visible(), false)
    sidebar:toggle()
    eq(sidebar:is_visible(), true)
    eq(state.calls[11].command[2], "split-window")
    sidebar:stop()
    eq(state.calls[14].command, { "tmux", "display-message", "-p", "-t", "%pane-1", "#{pane_id}\t#{pane_pid}" })
    eq(state.calls[15].command, { "tmux", "kill-pane", "-t", "%pane-1" })
    Runtime.registry[root], Runtime.active_root = nil, nil
  end)
  vim.fn.delete(root, "rf")
end

T["sidebar stop removes the detached pane without changing Neovim focus"] = function()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  with_tmux(function(state)
    local runtime = { root = root, client = { url = "http://127.0.0.1:1" }, username = "u", password = "p" }
    local source_win = vim.api.nvim_get_current_win()
    local sidebar = assert(require("opencode.ui.sidebar").new(runtime))
    sidebar:show_root(runtime)
    eq(vim.api.nvim_get_current_win(), source_win)
    sidebar:stop()
    eq(state.calls[3].command, { "tmux", "display-message", "-p", "-t", "%pane-1", "#{pane_id}\t#{pane_pid}" })
    eq(state.calls[4].command, { "tmux", "kill-pane", "-t", "%pane-1" })
  end)
  vim.fn.delete(root, "rf")
end

T["sidebar reports every missing tmux boundary clearly"] = function()
  for _, missing in ipairs({ "tmux", "TMUX", "TMUX_PANE" }) do
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    with_tmux(function(state)
      if missing == "tmux" then
        vim.fn.executable = function(name)
          return name == "tmux" and 0 or 1
        end
      elseif missing == "TMUX" then
        vim.env.TMUX = nil
      else
        vim.env.TMUX_PANE = nil
      end
      local runtime = { root = root, client = { url = "http://127.0.0.1:1" } }
      local shown, err = require("opencode.ui.sidebar").new(runtime):show_root(runtime)
      eq({ shown, err, #state.calls }, { false, "tmux_required", 0 }, missing)
    end)
    vim.fn.delete(root, "rf")
  end
end

T["sidebar replaces roots and stops only a revalidated pane identity"] = function()
  local first_root, second_root = vim.fn.tempname(), vim.fn.tempname()
  vim.fn.mkdir(first_root, "p")
  vim.fn.mkdir(second_root, "p")
  with_tmux(function(state)
    local first = {
      root = first_root,
      username = "one",
      password = "one-secret",
      client = { url = "http://127.0.0.1:1" },
      server_job = 11,
      jobs = { active = { state = "running" } },
    }
    local second = {
      root = second_root,
      username = "two",
      password = "two-secret",
      client = { url = "http://127.0.0.1:2" },
      server_job = 22,
      jobs = { active = { state = "running" } },
    }
    local first_sidebar = require("opencode.ui.sidebar").new(first)
    local second_sidebar = require("opencode.ui.sidebar").new(second)
    first_sidebar:show_root(first)
    second_sidebar:show_root(second)
    eq(state.calls[3].command, { "tmux", "display-message", "-p", "-t", "%pane-1", "#{pane_id}\t#{pane_pid}" })
    eq(state.calls[4].command, { "tmux", "display-message", "-p", "-t", "%pane-1", "#{pane_id}\t#{pane_pid}" })
    eq(state.calls[5].command, { "tmux", "kill-pane", "-t", "%pane-1" })
    eq(state.calls[6].command[2], "split-window")
    eq({ first.tui_live, second.tui_live, first.server_job, second.server_job }, { false, true, 11, 22 })
    eq({ first.jobs.active.state, second.jobs.active.state }, { "running", "running" })
    second_sidebar:stop()
  end)
  vim.fn.delete(first_root, "rf")
  vim.fn.delete(second_root, "rf")
end

T["sidebar refuses to kill a pane whose ID was reused with another PID"] = function()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  with_tmux(function(state)
    local runtime = { root = root, client = { url = "http://127.0.0.1:1" }, username = "u", password = "p" }
    local sidebar = require("opencode.ui.sidebar").new(runtime)
    sidebar:show_root(runtime)
    state.pane_pid = 7002
    eq(sidebar:hide(), true)
    eq(state.calls[3].command, { "tmux", "display-message", "-p", "-t", "%pane-1", "#{pane_id}\t#{pane_pid}" })
    eq(runtime.tui_status, "dead")
    for _, call in ipairs(state.calls) do
      eq(call.command[2] == "kill-pane", false)
    end
  end)
  vim.fn.delete(root, "rf")
end

T["AC-UI-03 status and notification identity remains readable without color"] = function()
  local runtime = require("opencode.runtime").new("/tmp/acceptance-ui-root")
  runtime.state, runtime.profile = "ready", { version = "1.18.9" }
  runtime.sessions = {
    ["ses_firstsame-tail"] = {
      id = "ses_firstsame-tail",
      title = "Alpha session",
      last_mode = "build",
      active_job_key = "job_first",
    },
    ["ses_secondsame-tail"] = { id = "ses_secondsame-tail", title = "Beta session", last_mode = "plan" },
  }
  runtime.jobs = {
    job_first = {
      key = "job_first",
      session_id = "ses_firstsame-tail",
      user_message_id = "msg_first",
      mode = "build",
      state = "running",
    },
  }
  local status = require("opencode.ui.status")
  local snapshot = status.snapshot(runtime)
  eq(snapshot.compatibility, "1.18.9")
  eq(snapshot.sessions[1].short_id ~= snapshot.sessions[2].short_id, true)
  local text = status.text(snapshot)
  eq(text:find("Alpha session", 1, true) ~= nil, true)
  eq(text:find("Beta session", 1, true) ~= nil, true)
  eq(text:find("Job=running/build", 1, true) ~= nil, true)
  eq(text:find("session", 1, true) ~= nil, true)

  local notify = require("opencode.ui.notify")
  local metadata = notify.snapshot(runtime, runtime.jobs.job_first)
  local message
  local original_notify, original_seen = vim.notify, notify.seen
  notify.seen = {}
  vim.notify = function(value)
    message = value
  end
  notify.emit("question", metadata, runtime)
  vim.notify, notify.seen = original_notify, original_seen
  eq(message:find(metadata.session_short_id, 1, true) ~= nil, true)
  eq(message:find("acceptance-ui-root", 1, true) ~= nil, true)
  eq(message:find("question waiting", 1, true) ~= nil, true)
end

T["AC-UI-04 background notifications identify every Job without changing source focus"] = function()
  local path, buf, source_win = source_buffer({ "source" }, "lua")
  vim.api.nvim_win_set_cursor(source_win, { 1, 2 })
  local sidebar_buf = vim.api.nvim_create_buf(false, true)
  local runtime = require("opencode.runtime").new(vim.fs.dirname(path))
  runtime.sidebar = { buf = sidebar_buf }
  runtime.sessions = {}
  runtime.jobs = {}
  local cases = {
    { kind = "completed", state = "completed", title = "done" },
    { kind = "conflict", state = "conflict", title = "conflict", conflict_kind = "agent" },
    { kind = "question", state = "waiting_user", title = "question", waiting_kind = "question" },
    { kind = "error", state = "error", title = "failed", error_class = "merge_process" },
  }
  for index, item in ipairs(cases) do
    local session_id, job_key = "ses_case_" .. index, "job_case_" .. index
    runtime.sessions[session_id] = { id = session_id, title = item.title, active_job_key = job_key }
    runtime.jobs[job_key] = {
      key = job_key,
      session_id = session_id,
      user_message_id = "msg_case_" .. index,
      root = runtime.root,
      mode = "build",
      state = item.state,
      conflict_kind = item.conflict_kind,
      waiting_kind = item.waiting_kind,
      error_class = item.error_class,
    }
  end
  local notify = require("opencode.ui.notify")
  local original_notify, original_seen = vim.notify, notify.seen
  local messages = {}
  notify.seen = {}
  vim.notify = function(value)
    table.insert(messages, value)
  end
  for index, item in ipairs(cases) do
    local job = runtime.jobs["job_case_" .. index]
    local metadata = notify.snapshot(runtime, job)
    notify.emit(item.kind, metadata, runtime)
    local message = messages[#messages]
    eq(message:find(metadata.root, 1, true) ~= nil, true)
    eq(message:find(metadata.session_short_id, 1, true) ~= nil, true)
    eq(message:find("state=" .. metadata.state, 1, true) ~= nil, true)
  end
  vim.notify, notify.seen = original_notify, original_seen
  eq(#messages, 4)
  for index, item in ipairs(cases) do
    local message = messages[index]
    eq(message:find("case_" .. index, 1, true) ~= nil, true)
    eq(message:find(item.kind == "error" and "error" or item.kind, 1, true) ~= nil, true)
    eq(notify.focus_safe(), true)
  end
  eq(vim.api.nvim_get_current_win(), source_win)
  eq(vim.api.nvim_win_get_cursor(source_win), { 1, 2 })
  eq(vim.api.nvim_buf_is_valid(sidebar_buf), true)
  vim.api.nvim_buf_delete(sidebar_buf, { force = true })
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["AC-CTX-01 context placeholders resolve file ranges and remain completable"] = function()
  local path, buf, source_win = source_buffer({ "local function alpha()", "  return 1", "end" }, "lua")
  local other_path = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "local beta = 2" }, other_path)
  vim.cmd.vsplit(vim.fn.fnameescape(other_path))
  local other_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_set_cursor(source_win, { 2, 2 })
  vim.api.nvim_buf_set_mark(buf, "A", 0, 0, {})
  vim.api.nvim_buf_set_mark(other_buf, "B", 0, 0, {})
  vim.diagnostic.set(vim.api.nvim_create_namespace("acceptance-context"), buf, {
    { lnum = 1, col = 1, message = "value is unusual" },
  }, {})
  local old_qflist = vim.fn.getqflist()
  vim.fn.setqflist({ { bufnr = other_buf, lnum = 1, col = 1 }, { text = "quickfix note" } }, "r")
  local capture = assert(require("opencode.context").capture())
  local context = require("opencode.context").new(capture, { root = vim.fs.dirname(path) })
  local rendered = context:render("@this @buffer @buffers @visible @diagnostics @quickfix @marks")
  for _, token in ipairs({ "@this", "@buffer", "@buffers", "@visible", "@diagnostics", "@quickfix" }) do
    eq(rendered.plaintext:find(token, 1, true), nil, token)
  end
  eq(rendered.plaintext:find("acceptance-context", 1, true) == nil, true)
  eq(rendered.plaintext:find(":L2:C3", 1, true) ~= nil, true)
  eq(rendered.plaintext:find("quickfix note", 1, true) ~= nil, true)
  eq(rendered.plaintext:find("value is unusual", 1, true) ~= nil, true)
  eq(context:render("Explain").plaintext:find(path:match("[^/]+$"), 1, true) ~= nil, true)
  local before = require("opencode.scope").resolve(
    context,
    { text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") }
  )
  context:render("@this")
  local after = require("opencode.scope").resolve(
    context,
    { text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") }
  )
  eq({ before.kind, before.start_byte, before.end_byte }, { after.kind, after.start_byte, after.end_byte })
  with_prompt_window(function(captured, fake)
    local prompt = require("opencode.ui.ask").ask("@buffer", context, "plan")
    local completion
    local server = require("opencode.ui.ask.cmp").cmd()
    server.request("textDocument/completion", {
      textDocument = { uri = vim.uri_from_bufnr(fake.buf) },
    }, function(_, result)
      completion = result
    end)
    eq(
      vim.wait(100, function()
        return completion ~= nil
      end),
      true
    )
    eq(
      vim.tbl_contains(
        vim.tbl_map(function(item)
          return item.label
        end, completion),
        "@buffer"
      ),
      true
    )
    local namespace = vim.api.nvim_get_namespaces().opencode_ask
    eq(#vim.api.nvim_buf_get_extmarks(fake.buf, namespace, 0, -1, {}) > 0, true)
    captured.keys.cancel[2]()
    eq(select(2, await(prompt)).error_class, "cancelled")
  end)
  vim.api.nvim_set_current_win(source_win)
  vim.cmd.only()
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.api.nvim_buf_delete(other_buf, { force = true })
  vim.fn.delete(path)
  vim.fn.delete(other_path)
  vim.fn.setqflist(old_qflist, "r")
end

T["AC-CTX-02 managed commands reject slash dispatch without duplicating command or skill syntax"] = function()
  local path, buf = source_buffer({ "plain" }, "text")
  local call_log = calls()
  local runtime = ready_runtime(vim.fs.dirname(path), call_log, "ses_ctx_02")
  local context = require("opencode.context").new(assert(require("opencode.context").capture()), runtime)
  local job =
    await(require("opencode.api.prompt").prompt("Use the project command and skill", context, { mode = "plan" }))
  eq(#call_log.prompts, 1)
  eq(call_log.prompts[1].parts[1].text:find("#command", 1, true), nil)
  eq(call_log.prompts[1].parts[1].text:find("#skill", 1, true), nil)
  require("opencode.job").finish(job, runtime.sessions.ses_ctx_02, "completed")
  local _, err = await(require("opencode.api.prompt").prompt("/deploy", context, { mode = "plan" }))
  eq(err.error_class, "command_unsupported")
  eq(call_log.creates, 1)
  eq(next(runtime.jobs), nil)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["AC-CTX-03 dirty save runs write hooks before Build captures Base and creates a Job"] = function()
  local path, buf = source_buffer({ "before" }, "text")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "dirty" })
  local hook_runs = 0
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = buf,
    once = true,
    callback = function()
      hook_runs = hook_runs + 1
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "final after hook" })
    end,
  })
  local call_log = calls()
  local runtime = ready_runtime(vim.fs.dirname(path), call_log, "ses_ctx_03")
  local context = require("opencode.context").new(assert(require("opencode.context").capture()), runtime)
  local original_select = vim.ui.select
  vim.ui.select = function(items, _, callback)
    eq(items, { "save and continue", "cancel" })
    callback("save and continue")
  end
  local job, err = await(require("opencode.api.prompt").prompt("build it", context, { mode = "build" }))
  vim.ui.select = original_select
  eq(err, nil)
  eq(hook_runs, 1)
  eq(vim.bo[buf].modified, false)
  eq(table.concat(vim.fn.readfile(path), "\n"), "final after hook")
  eq(job.base.text, "final after hook")
  eq(call_log.prompts[1].parts[1].text:find(vim.fn.sha256("final after hook"), 1, true) ~= nil, true)
  require("opencode.job").finish(job, runtime.sessions.ses_ctx_03, "completed")
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["AC-CTX-04 dirty cancel creates no prompt and leaves every dirty buffer unsaved"] = function()
  local path, buf = source_buffer({ "target" }, "text")
  local other_path = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ "other" }, other_path)
  local other_buf = vim.fn.bufadd(other_path)
  vim.fn.bufload(other_buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "target dirty" })
  vim.api.nvim_buf_set_lines(other_buf, 0, -1, false, { "other dirty" })
  local call_log = calls()
  local runtime = ready_runtime(vim.fs.dirname(path), call_log, "ses_ctx_04")
  local context = require("opencode.context").new(assert(require("opencode.context").capture()), runtime)
  context.referenced_buffers[other_buf] = true
  local original_select = vim.ui.select
  vim.ui.select = function(items, _, callback)
    eq(items, { "save and continue", "cancel" })
    callback("cancel")
  end
  local _, err = await(require("opencode.api.prompt").prompt("do not send", context, { mode = "build" }))
  vim.ui.select = original_select
  eq(err.error_class, "cancelled")
  eq(call_log.creates, 0)
  eq(#call_log.prompts, 0)
  eq(next(runtime.jobs), nil)
  eq(vim.bo[buf].modified, true)
  eq(vim.bo[other_buf].modified, true)
  vim.api.nvim_buf_delete(other_buf, { force = true })
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
  vim.fn.delete(other_path)
end

T["AC-CTX-05 unsupported targets fail with a specific reason before Job creation"] = function()
  local context_module = require("opencode.context")
  vim.cmd.enew()
  local _, err = context_module.capture()
  eq(err, "unnamed_buffer")
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(scratch, vim.fn.tempname())
  vim.api.nvim_set_current_buf(scratch)
  _, err = context_module.capture()
  eq(err, "unsupported_buffer")
  vim.api.nvim_buf_delete(scratch, { force = true })

  ---Writes arbitrary bytes so target validation can distinguish NUL data from invalid UTF-8.
  ---The bytes are supplied at the filesystem boundary; Context.capture remains the code under test.
  local function bytes_file(bytes)
    local path = vim.fn.tempname()
    local fd = assert(vim.uv.fs_open(path, "w", 420))
    assert(vim.uv.fs_write(fd, bytes, 0))
    vim.uv.fs_close(fd)
    vim.cmd.edit(vim.fn.fnameescape(path))
    local capture, reason = context_module.capture()
    return path, capture, reason
  end
  local nul_path, _, nul_reason = bytes_file("abc\0def")
  eq(nul_reason, "nul_file")
  vim.fn.delete(nul_path)
  local utf_path, _, utf_reason = bytes_file("abc" .. string.char(255))
  eq(utf_reason, "non_utf8_file")
  vim.fn.delete(utf_path)

  local path, buf = source_buffer({ "abc", "def" }, "text")
  local capture = assert(context_module.capture({ from = { 1, 0 }, to = { 1, 2 }, kind = "block" }))
  local call_log = calls()
  local runtime = ready_runtime(vim.fs.dirname(path), call_log, "ses_ctx_05")
  local context = context_module.new(capture, runtime)
  local _, block_err = await(require("opencode.api.prompt").prompt("build", context, { mode = "build" }))
  eq(block_err.error_class, "blockwise_selection")
  eq(call_log.creates, 0)
  local original_notify, notifications = vim.notify, {}
  vim.notify = function(message)
    table.insert(notifications, message)
  end
  vim.cmd.enew()
  require("opencode").prompt("build")
  eq(
    vim.wait(100, function()
      return #notifications > 0
    end),
    true
  )
  vim.notify = original_notify
  eq(notifications[1]:find("unnamed_buffer", 1, true) ~= nil, true)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["AC-CTX-06 Plan shares dirty save and cancel preflight and sends only after final write"] = function()
  local path, buf = source_buffer({ "plan before" }, "text")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "plan dirty" })
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = buf,
    once = true,
    callback = function()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "plan final" })
    end,
  })
  local call_log = calls()
  local runtime = ready_runtime(vim.fs.dirname(path), call_log, "ses_ctx_06")
  local context = require("opencode.context").new(assert(require("opencode.context").capture()), runtime)
  local original_select = vim.ui.select
  vim.ui.select = function(_, _, callback)
    callback("save and continue")
  end
  local plan_job, err = await(require("opencode.api.prompt").prompt("inspect", context, { mode = "plan" }))
  vim.ui.select = original_select
  eq(err, nil)
  eq(table.concat(vim.fn.readfile(path), "\n"), "plan final")
  eq(plan_job.mode, "plan")
  eq(call_log.prompts[1].agent, "plan")
  eq(call_log.prompts[1].format, nil)
  require("opencode.job").finish(plan_job, runtime.sessions.ses_ctx_06, "completed")

  local cancel_path, cancel_buf = source_buffer({ "cancel before" }, "text")
  vim.api.nvim_buf_set_lines(cancel_buf, 0, -1, false, { "cancel dirty" })
  local cancel_context = require("opencode.context").new(assert(require("opencode.context").capture()), runtime)
  vim.ui.select = function(_, _, callback)
    callback("cancel")
  end
  local _, cancel_err = await(require("opencode.api.prompt").prompt("cancel", cancel_context, { mode = "plan" }))
  vim.ui.select = original_select
  eq(cancel_err.error_class, "cancelled")
  eq(#call_log.prompts, 1)
  eq(vim.bo[cancel_buf].modified, true)
  vim.api.nvim_buf_delete(cancel_buf, { force = true })
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(cancel_path)
  vim.fn.delete(path)
end

T["AC-MODE-01 Plan permissions hard-deny writes while retaining read-only access"] = function()
  local path, buf = source_buffer({ "unchanged" }, "text")
  local permissions = require("opencode.session").permissions
  eq(require("opencode.session").verify_permissions(permissions), true)
  for _, denied in ipairs({ "edit", "bash", "task", "external_directory" }) do
    local found
    for _, rule in ipairs(permissions) do
      if rule.permission == denied then
        found = rule
      end
    end
    eq(found.action, "deny", denied)
  end
  local policy = require("opencode.events").permission_policy
  eq(policy("read"), "ask_once")
  eq(policy("edit"), "hard_reject")
  eq(policy("bash"), "hard_reject")
  eq(policy("task"), "hard_reject")
  eq(policy("unknown_custom_tool"), "hard_reject")
  eq(table.concat(vim.fn.readfile(path), "\n"), "unchanged")
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["AC-MODE-02 Build sends structured proposal with denied source-write tools and leaves disk unchanged"] = function()
  local path, buf = source_buffer({ "local value = 1" }, "lua")
  local original = table.concat(vim.fn.readfile(path), "\n")
  local call_log = calls()
  local runtime = ready_runtime(vim.fs.dirname(path), call_log, "ses_mode_02")
  local context = require("opencode.context").new(assert(require("opencode.context").capture()), runtime)
  local job, err = await(require("opencode.api.prompt").prompt("change value", context, { mode = "build" }))
  eq(err, nil)
  eq(call_log.create_payload.permission, require("opencode.session").permissions)
  eq(call_log.prompts[1].format.type, "json_schema")
  eq(vim.deep_equal(call_log.prompts[1].format.schema, require("opencode.proposal").schema), true)
  eq(call_log.prompts[1].parts[1].text:find("Return a structured replacement", 1, true) ~= nil, true)
  eq(call_log.prompts[1].parts[1].text:find("Base SHA-256:", 1, true) ~= nil, true)
  eq(table.concat(vim.fn.readfile(path), "\n"), original)
  eq(call_log.order, { "prompt" })
  eq({ call_log.selects, call_log.selected }, { 0, {} })
  local denied = {}
  for _, rule in ipairs(call_log.create_payload.permission) do
    if rule.action == "deny" then
      denied[rule.permission] = true
    end
  end
  eq(denied.edit and denied.bash and denied.task and denied.external_directory, true)
  require("opencode.job").finish(job, runtime.sessions.ses_mode_02, "completed")
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["AC-MODE-03 Plan to Build follow-up reuses the Session with a new Job identity and Base"] = function()
  local path, buf = source_buffer({ "local value = 1" }, "lua")
  local call_log = calls()
  local runtime = ready_runtime(vim.fs.dirname(path), call_log, "ses_mode_03")
  local context = require("opencode.context").new(assert(require("opencode.context").capture()), runtime)
  local plan_job = await(require("opencode.api.prompt").prompt("inspect", context, { mode = "plan" }))
  require("opencode.job").finish(plan_job, runtime.sessions.ses_mode_03, "completed")
  local second_job, err = await(require("opencode.api.prompt").prompt("now change", context, { mode = "build" }))
  eq(err, nil)
  eq(call_log.creates, 1)
  eq(call_log.updates > 0, true)
  eq(#call_log.prompts, 2)
  eq(call_log.order, { "split", "select", "prompt", "prompt" })
  eq(call_log.selected, { "ses_mode_03" })
  eq(plan_job.session_id, second_job.session_id)
  eq(plan_job.user_message_id ~= second_job.user_message_id, true)
  eq(plan_job.state, "completed")
  eq(second_job.mode, "build")
  eq(second_job.base.text, "local value = 1")
  eq(call_log.prompts[2].format.type, "json_schema")
  require("opencode.job").finish(second_job, runtime.sessions.ses_mode_03, "completed")
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["Plan and Build use mode-correct Session titles and payload profiles"] = function()
  local path, buf = source_buffer({ "local value = 1" }, "lua")
  local call_log = calls()
  local runtime = ready_runtime(vim.fs.dirname(path), call_log, "ses_mode_titles")
  local context = require("opencode.context").new(assert(require("opencode.context").capture()), runtime)
  local plan = await(require("opencode.api.prompt").prompt("inspect", context, { mode = "plan", new_session = true }))
  require("opencode.job").finish(plan, runtime.sessions.ses_mode_titles, "completed")
  local build = await(require("opencode.api.prompt").prompt("change", context, { mode = "build", new_session = true }))

  eq(call_log.create_payloads[1].title, "Plan " .. vim.fs.basename(path))
  eq(call_log.create_payloads[2].title, "Build " .. vim.fs.basename(path))
  eq({ call_log.prompts[1].agent, call_log.prompts[1].format }, { "plan", nil })
  eq(call_log.prompts[2].agent, "build")
  eq(call_log.prompts[2].format.type, "json_schema")
  eq(call_log.prompts[2].format.schema, require("opencode.proposal").schema)
  require("opencode.job").finish(build, runtime.sessions.ses_mode_titles, "completed")
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["AC-SCOPE-01 invocation range wins over stale visual marks"] = function()
  local path, buf = source_buffer({ "abcdef", "ghijkl" }, "text")
  vim.api.nvim_buf_set_mark(buf, "<", 0, 0, {})
  vim.api.nvim_buf_set_mark(buf, ">", 0, 5, {})
  local context_module = require("opencode.context")
  local capture = assert(context_module.capture({ from = { 2, 1 }, to = { 2, 3 }, kind = "char" }))
  local context = context_module.new(capture, { root = vim.fs.dirname(path) })
  local base = assert(require("opencode.snapshot").capture(buf))
  local scope = assert(require("opencode.scope").resolve(context, base))
  eq({ scope.start_byte, scope.end_byte }, { 8, 11 })
  context.range = { from = { 2, 0 }, to = { 2, 0 }, kind = "line" }
  scope = assert(require("opencode.scope").resolve(context, base))
  eq({ scope.start_byte, scope.end_byte }, { 7, 13 })
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["AC-SCOPE-02 Build defaults to function scope, permits file widening, and falls back to file scope"] = function()
  local path, buf, win = source_buffer({ "local function alpha()", "  return 1", "end", "local x = 2" }, "lua")
  vim.api.nvim_win_set_cursor(win, { 2, 2 })
  local context_module = require("opencode.context")
  local capture = assert(context_module.capture())
  local context = context_module.new(capture, { root = vim.fs.dirname(path) })
  local base = assert(require("opencode.snapshot").capture(buf))
  local function_scope = assert(require("opencode.scope").resolve(context, base))
  eq(function_scope.kind, "function")
  eq(function_scope.end_byte < #base.text, true)
  local file_scope = assert(require("opencode.scope").resolve(context, base, "file"))
  eq({ file_scope.kind, file_scope.start_byte, file_scope.end_byte }, { "file", 0, #base.text })
  vim.bo[buf].filetype = "text"
  local fallback = assert(require("opencode.scope").resolve(context, base))
  eq({ fallback.kind, fallback.start_byte, fallback.end_byte }, { "file", 0, #base.text })
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

return T
