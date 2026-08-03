---@diagnostic disable: duplicate-set-field

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
      local created_id = calls.create_ids and calls.create_ids[calls.creates] or session_id
      return Promise.resolve(detail(created_id))
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
    prompt_async = function(_, id, payload)
      table.insert(calls.order, "prompt")
      calls.prompt_session = id
      table.insert(calls.prompts, payload)
      if calls.fail_prompt then
        return Promise.reject({ error_class = "timeout" })
      end
      if calls.complete_during_prompt then
        local session = runtime.sessions[id]
        require("opencode.job").finish(runtime.jobs[session.active_job_key], session, "completed")
      end
      return Promise.resolve({})
    end,
    abort = function(_, id)
      calls.aborts = calls.aborts + 1
      calls.abort_id = id
      table.insert(calls.order, "abort")
      if calls.fail_abort then
        return Promise.reject({ error_class = "abort" })
      end
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
    prompts = {},
    order = {},
    aborts = 0,
  }
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
    for _, key in ipairs({ "newline_shift", "newline", "submit", "submit_normal", "cancel" }) do
      local mapping = opts.keys[key]
      if mapping then
        vim.keymap.set(mapping.mode or "i", mapping[1], function()
          return mapping[2]()
        end, { buffer = buf, expr = mapping.expr == true })
      end
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

---Runs public prompt calls against a ready Runtime fake while keeping capture, scope resolution, and dispatch real.
---Only Runtime acquisition and notification rendering are replaced, so concurrent jobs still cross the public API boundary.
---@param runtime table
---@param callback fun(opencode: table)
local function with_public_runtime(runtime, callback)
  local old_runtime, old_notify = package.loaded["opencode.runtime"], vim.notify
  package.loaded["opencode.runtime"] = {
    acquire = function()
      return runtime, Promise.resolve(runtime)
    end,
    current = function()
      return runtime
    end,
  }
  vim.notify = function() end
  local ok, err = xpcall(function()
    callback(require("opencode"))
  end, debug.traceback)
  package.loaded["opencode.runtime"] = old_runtime
  vim.notify = old_notify
  assert(ok, err)
end

T["AC-UI-01 inline Build prompt shows root and scope metadata and restores source focus"] = function()
  local path, buf, source_win = source_buffer({ "local function alpha()", "  return 1", "end" }, "lua")
  vim.api.nvim_win_set_cursor(source_win, { 2, 2 })
  local capture = assert(require("opencode.context").capture())
  local context = require("opencode.context").new(capture, { root = vim.fs.dirname(path) })
  with_prompt_window(function(captured, fake)
    local result = require("opencode.ui.ask").ask(nil, context, "build")
    captured.keys.submit_normal[2]()
    eq(await(result), "")
    eq(captured.title:find("Build", 1, true) ~= nil, true)
    eq(captured.title:find(vim.fs.basename(vim.fs.dirname(path)), 1, true) ~= nil, true)
    eq(captured.title:find("function", 1, true) ~= nil, true)
    eq(captured.title:find(path, 1, true), nil)
    eq(captured.wo.statuscolumn:find("󰚩", 1, true) ~= nil, true)
    eq(captured.width, 60)
    eq(captured.height, 1)
    eq(fake:text(), "")
  end)
  eq(vim.api.nvim_get_current_win(), source_win)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["Build prompt queues unchanged text until Runtime readiness resolves"] = function()
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
    eq(captured.footer[1][1], " Starting ")
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
    eq(captured.footer[1][1], " Submitting ")
    local value = await(result)
    eq(value, initial)
  end)
  eq(vim.api.nvim_get_current_win(), source_win)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["startup or dispatch failure keeps Build input available for retry"] = function()
  local path, buf = source_buffer({ "source" }, "text")
  local context =
    require("opencode.context").new(assert(require("opencode.context").capture()), { root = vim.fs.dirname(path) })
  local readiness = Promise.reject({ error_class = "startup_timeout" })
  local attempts, submitted = 0, {}
  local initial = "keep this\nand this"
  with_prompt_window(function(captured, fake)
    local result = require("opencode.ui.ask").ask(initial, context, "build", nil, readiness, function(text)
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
    eq(#captured.footer[1][1] <= 32, true)
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

T["Build editor mappings use Shift-CR and C-j for newline and CR for completion or submit"] = function()
  local path, buf = source_buffer({ "source" }, "text")
  local context =
    require("opencode.context").new(assert(require("opencode.context").capture()), { root = vim.fs.dirname(path) })
  local old_pumvisible = vim.fn.pumvisible
  local submitted = 0
  with_prompt_window(function(captured, fake)
    local result = require("opencode.ui.ask").ask("first", context, "build", nil, nil, function()
      submitted = submitted + 1
      return Promise.resolve(nil)
    end)
    captured.keys.newline[2]()
    eq(vim.api.nvim_buf_get_lines(fake.buf, 0, -1, false), { "first", "" })
    captured.keys.newline_shift[2]()
    eq(vim.api.nvim_buf_get_lines(fake.buf, 0, -1, false), { "first", "", "" })
    vim.fn.pumvisible = function()
      return 1
    end
    eq(captured.keys.submit[2](), "<C-y>")
    eq(submitted, 0)
    vim.fn.pumvisible = old_pumvisible
    captured.keys.submit[2]()
    eq(await(result), "first\n")
    eq(submitted, 1)
  end)
  vim.fn.pumvisible = old_pumvisible
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["prompt title shows Build root and effective scope metadata"] = function()
  local path, buf = source_buffer({ "source" }, "text")
  local context =
    require("opencode.context").new(assert(require("opencode.context").capture()), { root = vim.fs.dirname(path) })
  with_prompt_window(function(captured)
    local result = require("opencode.ui.ask").ask(nil, context, "build")
    eq(captured.title:find("Build", 1, true) ~= nil, true)
    eq(captured.title:find(vim.fs.basename(vim.fs.dirname(path)), 1, true) ~= nil, true)
    eq(captured.title:find("file", 1, true) ~= nil, true)
    eq(captured.title:find(path, 1, true), nil)
    eq(captured.wo.statuscolumn:find("󰚩", 1, true) ~= nil, true)
    eq({ captured.keys.submit[1], captured.keys.newline_shift[1], captured.keys.newline[1] }, {
      "<CR>",
      "<S-CR>",
      "<C-j>",
    })
    captured.keys.cancel[2]()
    eq(select(2, await(result)).error_class, "cancelled")
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["prompt geometry stays visible at an edge and grows with multiline input"] = function()
  local lines = {}
  for _ = 1, 15 do
    table.insert(lines, "edge")
  end
  local path, buf, source_win = source_buffer(lines, "text")
  vim.api.nvim_win_set_cursor(source_win, { 10, 4 })
  local capture = assert(require("opencode.context").capture())
  local context = require("opencode.context").new(capture, { root = vim.fs.dirname(path) })
  local cursor_screen_row = vim.fn.screenpos(source_win, 10, 5).row - 1
  with_prompt_window(function(captured, fake)
    local result = require("opencode.ui.ask").ask("one\ntwo", context, "build")
    local lines = math.max(vim.o.lines - vim.o.cmdheight, 1)
    eq(captured.row >= 0, true)
    eq(captured.col >= 0, true)
    eq(captured.row + captured.height + 2 <= lines, true)
    eq(captured.col + captured.width + 2 <= vim.o.columns, true)
    eq(captured.width, 60)
    eq(captured.row + captured.height + 2 <= cursor_screen_row, true)
    vim.api.nvim_buf_set_lines(fake.buf, 0, -1, false, { string.rep("wide", 20) })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = fake.buf })
    eq(captured.width, 60)
    eq(captured.height > 1, true)
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

T["placeholder highlighting does not expand providers or mark referenced buffers"] = function()
  local path, buf = source_buffer({ "source" }, "text")
  local context =
    require("opencode.context").new(assert(require("opencode.context").capture()), { root = vim.fs.dirname(path) })
  local config = require("opencode.config")
  local old_provider = config.opts.contexts["@buffer"]
  local provider_calls = 0
  config.opts.contexts["@buffer"] = function()
    provider_calls = provider_calls + 1
    return path
  end
  with_prompt_window(function(captured, fake)
    local result = require("opencode.ui.ask").ask("@buffer", context, "build")
    eq(provider_calls, 0)
    eq(context.referenced_buffers[buf], nil)
    local namespace = vim.api.nvim_get_namespaces().opencode_ask
    eq(#vim.api.nvim_buf_get_extmarks(fake.buf, namespace, 0, -1, {}) > 0, true)
    vim.api.nvim_buf_set_lines(fake.buf, 0, -1, false, { "@buffer again" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = fake.buf })
    eq(provider_calls, 0)
    eq(context.referenced_buffers[buf], nil)
    captured.keys.cancel[2]()
    eq(select(2, await(result)).error_class, "cancelled")
  end)
  config.opts.contexts["@buffer"] = old_provider
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["AC-UI-02 Build prompt does not require a TUI or tmux boundary"] = function()
  local path, buf = source_buffer({ "source" }, "text")
  local context = require("opencode.context").new(assert(require("opencode.context").capture()), {
    root = vim.fs.dirname(path),
  })
  with_prompt_window(function(captured)
    local result = require("opencode.ui.ask").ask(nil, context, "build")
    eq(captured.title:find("Build", 1, true) ~= nil, true)
    captured.keys.cancel[2]()
    eq(select(2, await(result)).error_class, "cancelled")
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
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
    ["ses_secondsame-tail"] = { id = "ses_secondsame-tail", title = "Beta session", last_mode = "build" },
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
  local runtime = require("opencode.runtime").new(vim.fs.dirname(path))
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
  local before = assert(
    require("opencode.scope").resolve(
      context,
      { text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") }
    )
  )
  context:render("@this")
  local after = assert(
    require("opencode.scope").resolve(
      context,
      { text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") }
    )
  )
  eq({ before.kind, before.start_byte, before.end_byte }, { after.kind, after.start_byte, after.end_byte })
  with_prompt_window(function(captured, fake)
    local prompt = require("opencode.ui.ask").ask("@buffer", context, "build")
    local completion
    ---@diagnostic disable-next-line: missing-parameter
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
    await(require("opencode.api.prompt").prompt("Use the project command and skill", context, { mode = "build" }))
  eq(#call_log.prompts, 1)
  eq(call_log.prompts[1].parts[1].text:find("#command", 1, true), nil)
  eq(call_log.prompts[1].parts[1].text:find("#skill", 1, true), nil)
  require("opencode.job").finish(job, runtime.sessions.ses_ctx_02, "completed")
  local _, err = await(require("opencode.api.prompt").prompt("/deploy", context, { mode = "build" }))
  eq(err.error_class, "command_unsupported")
  eq(call_log.creates, 1)
  eq(next(runtime.jobs), nil)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["AC-CTX-03 dirty Build saves through write hooks before capturing Base and creating a Job"] = function()
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
  local select_calls = 0
  vim.ui.select = function(_, _, callback)
    select_calls = select_calls + 1
    callback("save and continue")
  end
  local job, err = await(require("opencode.api.prompt").prompt("build it", context, { mode = "build" }))
  vim.ui.select = original_select
  eq(err, nil)
  eq(select_calls, 0)
  eq(hook_runs, 1)
  eq(vim.bo[buf].modified, false)
  eq(table.concat(vim.fn.readfile(path), "\n"), "final after hook")
  eq(job.base.text, "final after hook")
  eq(call_log.prompts[1].parts[1].text:find(vim.fn.sha256("final after hook"), 1, true) ~= nil, true)
  require("opencode.job").finish(job, runtime.sessions.ses_ctx_03, "completed")
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["format-on-save rebases file, function, and visual scopes onto the final Base"] = function()
  local cases = {
    { name = "file", opts = { mode = "build", scope = "file" } },
    { name = "function", cursor = { 2, 2 }, opts = { mode = "build" } },
    {
      name = "visual",
      range = { from = { 2, 2 }, to = { 2, 9 }, kind = "char" },
      opts = { mode = "build" },
    },
  }
  for index, case in ipairs(cases) do
    local path, buf, win = source_buffer({ "local function alpha()", "  return 1", "end" }, "lua")
    if case.cursor then
      vim.api.nvim_win_set_cursor(win, case.cursor)
    end
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "-- dirty" })
    local capture = assert(require("opencode.context").capture(case.range))
    vim.api.nvim_create_autocmd("BufWritePre", {
      buffer = buf,
      once = true,
      callback = function()
        vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- formatted" })
      end,
    })
    local call_log = calls()
    local runtime = ready_runtime(vim.fs.dirname(path), call_log, "ses_format_" .. index)
    local context = require("opencode.context").new(capture, runtime)

    local job, err = await(require("opencode.api.prompt").prompt("change it", context, case.opts))
    eq(err, nil, case.name)
    eq(job.base.text, "-- formatted\nlocal function alpha()\n  return 1\nend\n-- dirty", case.name)
    eq(vim.bo[buf].modified, false, case.name)
    eq(table.concat(vim.fn.readfile(path), "\n"), job.base.text, case.name)
    if case.name == "file" then
      eq({ job.scope.kind, job.scope.start_byte, job.scope.end_byte }, { "file", 0, #job.base.text }, case.name)
    elseif case.name == "function" then
      local selected = job.base.text:sub(job.scope.start_byte + 1, job.scope.end_byte)
      eq(job.scope.kind, "function", case.name)
      eq(selected, "local function alpha()\n  return 1\nend", case.name)
    else
      local selected = job.base.text:sub(job.scope.start_byte + 1, job.scope.end_byte)
      eq(job.scope.kind, "range", case.name)
      eq(selected, "return 1", case.name)
    end
    require("opencode.job").finish(job, runtime.sessions[job.session_id], "completed")
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(path)
  end
end

T["reference providers rerender and save dirty buffers discovered by write hooks"] = function()
  local path, buf = source_buffer({ "target" }, "text")
  local first_path = vim.fn.tempname() .. ".txt"
  local second_path = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ "first" }, first_path)
  vim.fn.writefile({ "second" }, second_path)
  local first_buf, second_buf = vim.fn.bufadd(first_path), vim.fn.bufadd(second_path)
  vim.fn.bufload(first_buf)
  vim.fn.bufload(second_buf)
  vim.api.nvim_buf_set_lines(first_buf, 0, -1, false, { "first dirty" })
  vim.api.nvim_buf_set_lines(second_buf, 0, -1, false, { "second dirty" })

  local expose_second = false
  local order = {}
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = first_buf,
    once = true,
    callback = function()
      table.insert(order, "first hook")
      expose_second = true
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = second_buf,
    once = true,
    callback = function()
      table.insert(order, "second hook")
    end,
  })

  local config = require("opencode.config")
  local old_provider = config.opts.contexts["@dynamic"]
  config.opts.contexts["@dynamic"] = function(context)
    table.insert(order, "provider")
    context.referenced_buffers[first_buf] = true
    local values = { assert(context.format({ buf = first_buf, rel = context.root })) }
    if expose_second then
      context.referenced_buffers[second_buf] = true
      table.insert(values, assert(context.format({ buf = second_buf, rel = context.root })))
    end
    return table.concat(values, ", ")
  end

  local call_log = calls()
  local runtime = ready_runtime(vim.fs.dirname(path), call_log, "ses_dynamic_refs")
  local context = require("opencode.context").new(assert(require("opencode.context").capture()), runtime)
  local job, err = await(require("opencode.api.prompt").prompt("inspect @dynamic", context, { mode = "build" }))
  config.opts.contexts["@dynamic"] = old_provider

  eq(err, nil)
  eq(order, { "provider", "first hook", "provider", "second hook", "provider" })
  eq(table.concat(vim.fn.readfile(first_path), "\n"), "first dirty")
  eq(table.concat(vim.fn.readfile(second_path), "\n"), "second dirty")
  eq(vim.bo[first_buf].modified, false)
  eq(vim.bo[second_buf].modified, false)
  eq(call_log.prompts[1].parts[1].text:find(vim.fs.basename(second_path), 1, true) ~= nil, true)

  require("opencode.job").finish(job, runtime.sessions.ses_dynamic_refs, "completed")
  vim.api.nvim_buf_delete(first_buf, { force = true })
  vim.api.nvim_buf_delete(second_buf, { force = true })
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(first_path)
  vim.fn.delete(second_path)
  vim.fn.delete(path)
end

T["AC-CTX-04 Build dirty buffers save automatically without a confirmation dialog"] = function()
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
  local select_calls = 0
  vim.ui.select = function()
    select_calls = select_calls + 1
  end
  local job, err = await(require("opencode.api.prompt").prompt("send", context, { mode = "build" }))
  vim.ui.select = original_select
  eq(err, nil)
  eq(select_calls, 0)
  eq(call_log.creates, 1)
  eq(#call_log.prompts, 1)
  eq(vim.bo[buf].modified, false)
  eq(vim.bo[other_buf].modified, false)
  eq(table.concat(vim.fn.readfile(path), "\n"), "target dirty")
  eq(table.concat(vim.fn.readfile(other_path), "\n"), "other dirty")
  require("opencode.job").finish(job, runtime.sessions.ses_ctx_04, "completed")
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

T["AC-CTX-06 Build dispatch uses the final dirty-buffer contents in its proposal"] = function()
  local path, buf = source_buffer({ "before" }, "text")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "dirty" })
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = buf,
    once = true,
    callback = function()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "final" })
    end,
  })
  local call_log = calls()
  local runtime = ready_runtime(vim.fs.dirname(path), call_log, "ses_ctx_06")
  local context = require("opencode.context").new(assert(require("opencode.context").capture()), runtime)
  local job, err = await(require("opencode.api.prompt").prompt("inspect", context, { mode = "build" }))
  eq(err, nil)
  eq(table.concat(vim.fn.readfile(path), "\n"), "final")
  eq(job.mode, "build")
  eq(call_log.prompts[1].agent, "build")
  eq(call_log.prompts[1].format.type, "json_schema")
  require("opencode.job").finish(job, runtime.sessions.ses_ctx_06, "completed")
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["AC-MODE-01 Build permissions hard-deny source writes while retaining read-only access"] = function()
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

T["Build new_session creates a fresh Session instead of reusing the selected one"] = function()
  local path, buf = source_buffer({ "local value = 1" }, "lua")
  local call_log = calls()
  call_log.create_ids = { "ses_first", "ses_second" }
  local runtime = ready_runtime(vim.fs.dirname(path), call_log, "ses_first")
  local context = require("opencode.context").new(assert(require("opencode.context").capture()), runtime)

  local first, first_error = await(require("opencode.api.prompt").prompt("inspect", context, { mode = "build" }))
  eq(first_error, nil)
  require("opencode.job").finish(first, runtime.sessions.ses_first, "completed")
  runtime.sessions.ses_first.remote_status = "idle"
  runtime.sessions.ses_first.availability = "reusable"
  eq(runtime.selected_session_id, "ses_first")

  local second, second_error =
    await(require("opencode.api.prompt").prompt("inspect again", context, { mode = "build", new_session = true }))
  eq(second_error, nil)
  eq(call_log.creates, 2)
  eq(second.session_id, "ses_second")
  eq(second.session_id ~= first.session_id, true)
  eq(second.user_message_id ~= first.user_message_id, true)
  eq(runtime.selected_session_id, "ses_second")
  eq(runtime.sessions.ses_first.active_job_key, nil)
  require("opencode.job").finish(second, runtime.sessions.ses_second, "completed")

  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["public Build dispatch uses the active visual range for concurrent scope checks"] = function()
  local path, buf, win = source_buffer({
    "local function alpha()",
    "  return 1",
    "end",
    "",
    "local function beta()",
    "  return 2",
    "end",
  }, "lua")
  local call_log = calls()
  call_log.create_ids = { "ses_alpha", "ses_beta" }
  local runtime = ready_runtime(vim.fs.dirname(path), call_log, "ses_unused")
  local prompt_resolvers = {}
  runtime.client.prompt_async = function(_, session_id, payload)
    table.insert(call_log.order, "prompt")
    call_log.prompt_sessions = call_log.prompt_sessions or {}
    table.insert(call_log.prompt_sessions, session_id)
    table.insert(call_log.prompts, payload)
    local request, resolve = Promise.with_resolvers()
    table.insert(prompt_resolvers, resolve)
    return request
  end

  with_public_runtime(runtime, function(opencode)
    vim.api.nvim_win_set_cursor(win, { 2, 2 })
    local first_flow = opencode.prompt("inspect alpha", { mode = "build", new_session = true })
    eq(
      vim.wait(1000, function()
        return #prompt_resolvers == 1
      end),
      true
    )
    prompt_resolvers[1]({})
    local first_job, first_error = await(first_flow)
    eq(first_error, nil)
    eq({ first_job.session_id, first_job.state, runtime.selected_session_id }, { "ses_alpha", "running", "ses_alpha" })

    vim.api.nvim_buf_set_mark(buf, "<", 1, 0, {})
    vim.api.nvim_buf_set_mark(buf, ">", 3, 0, {})
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
    vim.cmd("normal! V2j")
    eq(vim.fn.mode(), "V")
    eq({ vim.api.nvim_buf_get_mark(buf, "<"), vim.api.nvim_buf_get_mark(buf, ">") }, { { 1, 0 }, { 3, 0 } })
    local second_flow = opencode.prompt("inspect beta", { mode = "build", new_session = true })
    eq(
      vim.wait(1000, function()
        return #prompt_resolvers == 2
      end),
      true
    )
    local second_job = assert(runtime.jobs[runtime.sessions.ses_beta.active_job_key])
    eq({ call_log.creates, #call_log.prompts }, { 2, 2 })
    eq(call_log.prompt_sessions, { "ses_alpha", "ses_beta" })
    eq({ first_job.mode, second_job.mode }, { "build", "build" })
    eq({ first_job.state, second_job.state }, { "running", "running" })
    eq(first_job.session_id ~= second_job.session_id, true)
    eq(first_job.user_message_id ~= second_job.user_message_id, true)
    eq(first_job.scope.kind, "function")
    eq(second_job.scope.kind, "range")
    eq(
      first_job.base.text:sub(first_job.scope.start_byte + 1, first_job.scope.end_byte),
      "local function alpha()\n  return 1\nend"
    )
    eq(
      second_job.base.text:sub(second_job.scope.start_byte + 1, second_job.scope.end_byte),
      "local function beta()\n  return 2\nend"
    )
    eq(require("opencode.scope").overlaps(first_job.scope, second_job.scope), false)

    vim.cmd("normal! <Esc>")
    vim.api.nvim_win_set_cursor(win, { 2, 2 })
    local _, overlap_error = await(opencode.prompt("inspect alpha again", { mode = "build", new_session = true }))
    eq(overlap_error.error_class, "scope_overlap")
    eq({ call_log.creates, #call_log.prompts, vim.tbl_count(runtime.jobs) }, { 2, 2, 2 })
    eq({ first_job.state, second_job.state }, { "running", "running" })

    prompt_resolvers[2]({})
    local returned_second, second_error = await(second_flow)
    eq(second_error, nil)
    eq(returned_second, second_job)
    require("opencode.job").finish(first_job, runtime.sessions[first_job.session_id], "completed")
    require("opencode.job").finish(second_job, runtime.sessions[second_job.session_id], "completed")
  end)

  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["session picker reuses the chosen Session through the Build prompt boundary"] = function()
  local picker, picker_options, ask_options, dispatched
  local old_modules, module_names = {}, {}
  ---Replaces one picker-side boundary and records its original module for deterministic restoration.
  local function replace(name, value)
    old_modules[name] = package.loaded[name]
    module_names[name] = true
    package.loaded[name] = value
  end
  local runtime = { root = "/picker-root", selected_session_id = "ses_previous" }
  local context = { root = runtime.root, path = runtime.root .. "/file.lua" }
  local selected = {
    id = "ses_picker",
    directory = runtime.root,
    title = "Reusable",
    short_id = "ses_pick",
    availability = "reusable",
    remote_status = "idle",
    activity = 1,
  }
  replace("opencode.session", {
    inventory = function()
      return Promise.resolve({ selected })
    end,
    availability = function()
      return "reusable"
    end,
  })
  replace("snacks", {
    picker = function(opts)
      picker_options = opts
      picker = { close = function() end }
      return picker
    end,
  })
  replace("opencode.context.preflight", {
    run = function()
      return Promise.resolve(true)
    end,
  })
  replace("opencode.ui.ask", {
    ask = function(_, captured, mode, opts, _, submit)
      ask_options = { context = captured, mode = mode, opts = opts }
      submit("continue")
      return Promise.resolve("continue")
    end,
  })
  replace("opencode.api.prompt", {
    prompt = function(text, captured, opts)
      dispatched = { text = text, context = captured, opts = opts }
      return Promise.resolve({})
    end,
  })

  local flow = require("opencode.ui.session_picker").open(runtime, context, { mode = "build" })
  eq(
    vim.wait(500, function()
      return picker_options ~= nil
    end),
    true
  )
  picker_options.actions.confirm(picker, picker_options.items[1])
  local result, error = await(flow)

  for name in pairs(module_names) do
    package.loaded[name] = old_modules[name]
  end
  eq(error, nil)
  eq(picker_options.title, "OpenCode Sessions")
  eq(
    picker_options.items[1].text:find("Reusable", 1, true) < picker_options.items[1].text:find("ses_pick", 1, true),
    true
  )
  eq(picker_options.items[1].preview.text:sub(1, 15), "Title: Reusable")
  eq(ask_options.context, context)
  eq(ask_options.mode, "build")
  eq(ask_options.opts.session_id, "ses_picker")
  eq(dispatched.opts.session_id, "ses_picker")
  eq(runtime.selected_session_id, "ses_picker")
  eq(result, {})
end

T["ambiguous prompt failure aborts before releasing the Session"] = function()
  local path, buf = source_buffer({ "local value = 1" }, "lua")
  local call_log = calls()
  call_log.fail_prompt = true
  local runtime = ready_runtime(vim.fs.dirname(path), call_log, "ses_prompt_timeout")
  local context = require("opencode.context").new(assert(require("opencode.context").capture()), runtime)

  local _, err = await(require("opencode.api.prompt").prompt("inspect", context, { mode = "build" }))
  local session = runtime.sessions.ses_prompt_timeout
  eq(err.error_class, "timeout")
  eq({ call_log.aborts, session.active_job_key, session.remote_status, session.availability }, {
    1,
    nil,
    "idle",
    "reusable",
  })
  eq(call_log.order, { "prompt", "abort" })

  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["correlated completion before HTTP acknowledgment remains successful"] = function()
  local path, buf = source_buffer({ "local value = 1" }, "lua")
  local call_log = calls()
  call_log.complete_during_prompt = true
  local runtime = ready_runtime(vim.fs.dirname(path), call_log, "ses_fast_complete")
  local context = require("opencode.context").new(assert(require("opencode.context").capture()), runtime)

  local job, err = await(require("opencode.api.prompt").prompt("inspect", context, { mode = "build" }))
  eq(err, nil)
  eq({ job.state, call_log.aborts, call_log.order }, { "completed", 0, { "prompt" } })

  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["late runtime blocker does not register a local Job"] = function()
  local path, buf = source_buffer({ "local value = 1" }, "lua")
  local call_log = calls()
  local runtime = ready_runtime(vim.fs.dirname(path), call_log, "ses_late_blocker")
  local get_session = runtime.client.get_session
  runtime.client.get_session = function(client, id)
    runtime.state = "error"
    return get_session(client, id)
  end
  local context = require("opencode.context").new(assert(require("opencode.context").capture()), runtime)

  local _, err = await(require("opencode.api.prompt").prompt("inspect", context, { mode = "build" }))
  eq(err.error_class, "runtime_not_ready")
  eq({ next(runtime.jobs), next(runtime.sessions), #call_log.prompts }, { nil, nil, 0 })

  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["AC-MODE-03 Build follow-up reuses the Session with a new Job identity and Base"] = function()
  local path, buf = source_buffer({ "local value = 1" }, "lua")
  local call_log = calls()
  local runtime = ready_runtime(vim.fs.dirname(path), call_log, "ses_mode_03")
  local context = require("opencode.context").new(assert(require("opencode.context").capture()), runtime)
  local first_job = await(require("opencode.api.prompt").prompt("inspect", context, { mode = "build" }))
  require("opencode.job").finish(first_job, runtime.sessions.ses_mode_03, "completed")
  runtime.sessions.ses_mode_03.remote_status = "idle"
  runtime.sessions.ses_mode_03.availability = "reusable"
  local second_job, err = await(require("opencode.api.prompt").prompt("now change", context, { mode = "build" }))
  eq(err, nil)
  eq(call_log.creates, 1)
  eq(call_log.updates, 1)
  eq(#call_log.prompts, 2)
  eq(call_log.order, { "prompt", "prompt" })
  eq(first_job.session_id, second_job.session_id)
  eq(first_job.user_message_id ~= second_job.user_message_id, true)
  eq(first_job.state, "completed")
  eq(second_job.mode, "build")
  eq(second_job.base.text, "local value = 1")
  eq(call_log.prompts[2].format.type, "json_schema")
  require("opencode.job").finish(second_job, runtime.sessions.ses_mode_03, "completed")
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
end

T["Build requests let OpenCode auto-title sessions and use structured payload profiles"] = function()
  local path, buf = source_buffer({ "local value = 1" }, "lua")
  local call_log = calls()
  local runtime = ready_runtime(vim.fs.dirname(path), call_log, "ses_mode_titles")
  local context = require("opencode.context").new(assert(require("opencode.context").capture()), runtime)
  local first = await(require("opencode.api.prompt").prompt("inspect", context, { mode = "build", new_session = true }))
  require("opencode.job").finish(first, runtime.sessions.ses_mode_titles, "completed")
  local second = await(require("opencode.api.prompt").prompt("change", context, { mode = "build", new_session = true }))

  eq(call_log.create_payloads[1].title, nil)
  eq(call_log.create_payloads[2].title, nil)
  eq({ call_log.prompts[1].agent, call_log.prompts[1].format.type }, { "build", "json_schema" })
  eq(call_log.prompts[2].agent, "build")
  eq(call_log.prompts[2].format.type, "json_schema")
  eq(call_log.prompts[2].format.schema, require("opencode.proposal").schema)
  require("opencode.job").finish(second, runtime.sessions.ses_mode_titles, "completed")
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
