---@diagnostic disable: duplicate-set-field, need-check-nil

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function logical(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

---Writes bytes without Neovim's line-ending conversion, then opens the file as the source buffer.
---The raw write keeps CRLF, missing final newlines, and empty files observable at the snapshot boundary.
---It uses a private temporary directory so each acceptance case owns its disk and buffer state.
local function open_fixture(raw)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local path = root .. "/target.lua"
  local handle = assert(vim.uv.fs_open(path, "w", 420))
  assert(vim.uv.fs_write(handle, raw, 0))
  vim.uv.fs_close(handle)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return { root = root, path = path, buf = vim.api.nvim_get_current_buf() }
end

---Removes the buffer, extmarks, runtime registry entry, and private files owned by one fixture.
---Forceful cleanup is intentional because completed Jobs remove their own marks before the test returns.
local function close_fixture(fixture, runtime, jobs)
  if jobs then
    for _, job in pairs(jobs) do
      require("opencode.scope").delete_marks(job)
    end
  end
  if runtime then
    require("opencode.runtime").registry[runtime.root] = nil
    if runtime.temp_root then
      vim.fn.delete(runtime.temp_root, "rf")
    end
  end
  if vim.api.nvim_buf_is_valid(fixture.buf) then
    vim.api.nvim_buf_delete(fixture.buf, { force = true })
  end
  vim.fn.delete(fixture.root, "rf")
end

---Creates the smallest Runtime and Job assembly accepted by the snapshot, scope, and apply modules.
local function new_runtime_job(fixture, key, scope, theirs, state, base_override)
  local Runtime = require("opencode.runtime")
  local runtime = Runtime.new(fixture.root)
  runtime.generation = 1
  runtime.temp_root = vim.fn.tempname()
  vim.fn.mkdir(runtime.temp_root, "p")
  Runtime.registry[runtime.root] = runtime

  local session_id = "session_" .. key
  local session = { id = session_id, active_job_key = key }
  local job = {
    key = key,
    merge_key = fixture.root .. ":" .. key,
    root = fixture.root,
    session_id = session_id,
    user_message_id = "message_" .. key,
    mode = "build",
    state = state or "pending_apply",
    buffer = fixture.buf,
    path = fixture.path,
    base = base_override or assert(require("opencode.snapshot").capture(fixture.buf)),
    scope = scope,
    theirs = theirs,
  }
  job.marks = require("opencode.scope").create_marks(fixture.buf, scope)
  runtime.sessions[session_id], runtime.jobs[key] = session, job
  return runtime, job, session
end

---Returns a fixed half-open byte range for a literal fixture fragment.
---Using named fragments makes expected scopes readable while leaving production offset calculations under test.
local function fragment_range(path, text, fragment)
  local start_byte = assert(text:find(fragment, 1, true)) - 1
  return { kind = "range", path = path, start_byte = start_byte, end_byte = start_byte + #fragment }
end

---Waits for the apply Promise and Neovim scheduled callbacks to settle on one observable Job state.
---The bounded main-loop wait avoids sleeping while still exposing a missing callback as a test failure.
local function wait_for_state(job, state)
  eq(
    vim.wait(1000, function()
      return job.state == state
    end),
    true
  )
end

T["AC-SCOPE-03 rejects a Job whose local path escapes its root"] = function()
  local fixture = open_fixture("local alpha = 1\nlocal beta = 2")
  local snapshot = require("opencode.snapshot")
  local base = assert(snapshot.capture(fixture.buf))
  local scope = fragment_range(fixture.path, base.text, "alpha")
  local runtime, job, session = new_runtime_job(fixture, "scope_03", scope, base.text, "running")
  local before_buffer, before_disk = logical(fixture.buf), assert(snapshot.read_raw(fixture.path))
  job.path = vim.fn.tempname()
  eq(
    require("opencode.runtime.reconcile").complete_job(runtime, session, job, {
      {
        info = {
          id = "assistant_scope_03",
          role = "assistant",
          parentID = job.user_message_id,
          structured = { replacement = "ALPHA", summary = "change" },
        },
      },
    }),
    false
  )
  eq({ job.state, job.error_class, job.conflict_kind }, { "scope_violation", "scope_violation", nil })
  eq(logical(fixture.buf), before_buffer)
  eq(select(1, snapshot.read_raw(fixture.path)), before_disk)
  close_fixture(fixture, runtime, { job = job })
end

T["AC-SCOPE-04 rejects overlap and permits the adjacent beta scope"] = function()
  local fixture = open_fixture("alpha\nbeta")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local alpha = fragment_range(fixture.path, base.text, "alpha")
  local beta = fragment_range(fixture.path, base.text, "beta")
  local runtime, first = new_runtime_job(fixture, "scope_04_a", alpha, base.text, "running")
  local second = {
    key = "scope_04_b",
    mode = "build",
    state = "running",
    buffer = fixture.buf,
    scope = beta,
    marks = require("opencode.scope").create_marks(fixture.buf, beta),
  }
  runtime.jobs[second.key] = second
  local overlap = require("opencode.scope").find_overlap(runtime, fixture.buf, alpha)
  eq(overlap.key, first.key)
  eq(require("opencode.scope").find_overlap(runtime, fixture.buf, beta, second.key), nil)
  eq(vim.tbl_count(runtime.jobs), 2)
  close_fixture(fixture, runtime, { first = first, second = second })
end

T["AC-SCOPE-05 keeps Base offsets fixed while extmarks follow inserted lines"] = function()
  local fixture = open_fixture("local alpha = 1\n\nlocal beta = 2")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = fragment_range(fixture.path, base.text, "local beta = 2")
  local runtime, job = new_runtime_job(fixture, "scope_05", scope, base.text)
  local before = require("opencode.scope").current_range(job)
  vim.api.nvim_buf_set_lines(fixture.buf, 0, 0, false, { "-- inserted", "" })
  local current = assert(require("opencode.scope").current_range(job))
  eq({ current.start_byte, current.end_byte }, { before.start_byte + 13, before.end_byte + 13 })
  eq({ job.base.text, job.scope.start_byte, job.scope.end_byte }, { base.text, scope.start_byte, scope.end_byte })
  close_fixture(fixture, runtime, { job = job })
end

T["AC-SCOPE-06 stops apply when editing collapses another active scope"] = function()
  local fixture = open_fixture("alpha beta")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local first_scope = fragment_range(fixture.path, base.text, "alpha")
  local second_scope = fragment_range(fixture.path, base.text, "beta")
  local runtime, first = new_runtime_job(fixture, "scope_06_a", first_scope, "ALPHA beta")
  local second = {
    key = "scope_06_b",
    root = fixture.root,
    session_id = "session_scope_06_b",
    mode = "build",
    state = "pending_apply",
    buffer = fixture.buf,
    path = fixture.path,
    base = base,
    scope = second_scope,
    marks = require("opencode.scope").create_marks(fixture.buf, second_scope),
    theirs = "alpha BETA",
  }
  runtime.sessions[second.session_id] = { id = second.session_id, active_job_key = second.key }
  runtime.jobs[second.key] = second
  vim.api.nvim_buf_set_text(fixture.buf, 0, second_scope.start_byte, 0, second_scope.end_byte, { "" })
  local before = logical(fixture.buf)
  require("opencode.apply").start(first, runtime)
  eq(first.state, "scope_violation")
  eq(second.state, "pending_apply")
  eq(logical(fixture.buf), before)
  close_fixture(fixture, runtime, { first = first, second = second })
end

T["AC-PROP-01 constructs exact Base prefix replacement suffix Theirs"] = function()
  local fixture = open_fixture("one\ntwo\nthree")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = fragment_range(fixture.path, base.text, "two")
  local runtime, job = new_runtime_job(fixture, "prop_01", scope, base.text)
  local result = assert(require("opencode.proposal").validate({
    replacement = "TWO",
    summary = "replace one word",
  }, job))
  eq(result.proposal.path, "target.lua")
  eq(result.proposal.base_sha256, base.sha256)
  eq(result.proposal.scope, { start_byte = scope.start_byte, end_byte = scope.end_byte })
  eq(result.theirs, "one\nTWO\nthree")
  eq(logical(fixture.buf), base.text)
  eq(select(1, require("opencode.snapshot").read_raw(fixture.path)), "one\ntwo\nthree")
  close_fixture(fixture, runtime, { job = job })
end

T["AC-PROP-02 rejects missing or Markdown structured output without applying"] = function()
  local fixture = open_fixture("one\ntwo")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = fragment_range(fixture.path, base.text, "two")
  local runtime, job, session = new_runtime_job(fixture, "prop_02", scope, base.text, "running")
  local before = logical(fixture.buf)
  eq(
    require("opencode.runtime.reconcile").complete_job(runtime, session, job, {
      { info = { id = "assistant_prop_02", role = "assistant", parentID = job.user_message_id } },
    }),
    false
  )
  eq({ job.state, job.error_class }, { "error", "structured_output_count" })
  local proposal, err = require("opencode.proposal").validate(nil, job)
  eq(proposal, nil)
  eq(err.error_class, "invalid_structured_output")
  for _, value in ipairs({ "```diff\n-one\n+two\n```", { version = 1 } }) do
    proposal, err = require("opencode.proposal").validate(value, job)
    eq(proposal, nil)
    eq(err.error_class, "invalid_structured_output")
  end
  eq(job.theirs, nil)
  eq(logical(fixture.buf), before)
  eq(select(1, require("opencode.snapshot").read_raw(fixture.path)), before)
  close_fixture(fixture, runtime, { job = job })
end

T["AC-PROP-03 rejects model-authored transaction identity"] = function()
  local fixture = open_fixture("alpha\nbeta")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = fragment_range(fixture.path, base.text, "alpha")
  local runtime, job = new_runtime_job(fixture, "prop_03", scope, base.text)
  local result, err = require("opencode.proposal").validate({
    path = "other.lua",
    replacement = "ALPHA",
    summary = "change",
  }, job)
  eq(result, nil)
  eq(err.error_class, "invalid_structured_output")
  eq(job.theirs, base.text)
  eq(logical(fixture.buf), base.text)
  close_fixture(fixture, runtime, { job = job })
end

T["AC-MERGE-01 applies a clean agent change only to the modified buffer"] = function()
  local fixture = open_fixture("one\ntwo\nthree")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = fragment_range(fixture.path, base.text, "two")
  local runtime, job = new_runtime_job(fixture, "merge_01", scope, "one\nTWO\nthree")
  require("opencode.apply").start(job, runtime)
  wait_for_state(job, "completed")
  eq(logical(fixture.buf), "one\nTWO\nthree")
  eq(select(1, require("opencode.snapshot").read_raw(fixture.path)), base.text)
  eq(vim.bo[fixture.buf].modified, true)
  close_fixture(fixture, runtime, { job = job })
end

T["AC-MERGE-02 merges noncolliding user alpha and agent beta changes"] = function()
  local fixture = open_fixture("local function alpha()\n  return 1\nend\n\nlocal function beta()\n  return 2\nend")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local beta = fragment_range(fixture.path, base.text, "return 2")
  local theirs = base.text:gsub("return 2", "return 20", 1)
  local runtime, job = new_runtime_job(fixture, "merge_02", beta, theirs, nil, base)
  local ours = base.text:gsub("return 1", "return 10", 1)
  vim.api.nvim_buf_set_lines(fixture.buf, 0, -1, false, vim.split(ours, "\n", { plain = true }))
  require("opencode.apply").start(job, runtime)
  wait_for_state(job, "completed")
  eq(logical(fixture.buf), ours:gsub("return 2", "return 20", 1))
  eq(require("opencode.interaction").current, nil)
  close_fixture(fixture, runtime, { job = job })
end

T["AC-MERGE-03 applies an identical Ours and Theirs change once"] = function()
  local fixture = open_fixture("one\ntwo\nthree")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = fragment_range(fixture.path, base.text, "two")
  local changed = "one\nTWO\nthree"
  local runtime, job = new_runtime_job(fixture, "merge_03", scope, changed, nil, base)
  vim.api.nvim_buf_set_lines(fixture.buf, 0, -1, false, vim.split(changed, "\n", { plain = true }))
  require("opencode.apply").start(job, runtime)
  wait_for_state(job, "completed")
  eq(logical(fixture.buf), changed)
  eq(select(1, require("opencode.snapshot").read_raw(fixture.path)), base.text)
  close_fixture(fixture, runtime, { job = job })
end

T["AC-MERGE-04 defers completion in Insert mode until InsertLeave"] = function()
  local fixture = open_fixture("one\ntwo")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = fragment_range(fixture.path, base.text, "two")
  local runtime, job = new_runtime_job(fixture, "merge_04", scope, "one\nTWO")
  local real_mode = vim.api.nvim_get_mode
  vim.api.nvim_get_mode = function()
    return { mode = "i", blocking = false }
  end
  require("opencode.apply").start(job, runtime)
  vim.api.nvim_get_mode = real_mode
  eq(job.state, "pending_apply")
  eq(logical(fixture.buf), base.text)
  vim.api.nvim_exec_autocmds("InsertLeave", { buffer = fixture.buf })
  wait_for_state(job, "completed")
  eq(logical(fixture.buf), "one\nTWO")
  close_fixture(fixture, runtime, { job = job })
end

T["AC-MERGE-05 discards a stale changedtick result and merges fresh Ours"] = function()
  local fixture = open_fixture("alpha\nbeta")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = fragment_range(fixture.path, base.text, "beta")
  local runtime, job = new_runtime_job(fixture, "merge_05", scope, "alpha\nBETA")
  local real_merge = require("opencode.merge")
  local Promise = require("opencode.promise")
  local calls = 0
  package.loaded["opencode.merge"] = {
    run = function(first, ours, theirs, opts)
      calls = calls + 1
      return Promise.new(function(resolve, reject)
        vim.defer_fn(function()
          real_merge.run(first, ours, theirs, opts):next(resolve):catch(reject)
        end, 10)
      end)
    end,
    cleanup = real_merge.cleanup,
  }
  require("opencode.apply").start(job, runtime)
  vim.api.nvim_buf_set_lines(fixture.buf, 0, 1, false, { "ALPHA" })
  wait_for_state(job, "completed")
  package.loaded["opencode.merge"] = real_merge
  eq(calls, 2)
  eq(logical(fixture.buf), "ALPHA\nBETA")
  eq(select(1, require("opencode.snapshot").read_raw(fixture.path)), base.text)
  close_fixture(fixture, runtime, { job = job })
end

T["AC-MERGE-05 restarts a changed Runtime generation before applying"] = function()
  local fixture = open_fixture("alpha\nbeta")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = fragment_range(fixture.path, base.text, "beta")
  local runtime, job = new_runtime_job(fixture, "merge_05_generation", scope, "alpha\nBETA")
  local real_merge = require("opencode.merge")
  local Promise = require("opencode.promise")
  local calls = 0
  package.loaded["opencode.merge"] = {
    run = function()
      calls = calls + 1
      if calls == 1 then
        runtime.generation = runtime.generation + 1
      end
      return Promise.resolve({ kind = "clean", text = job.theirs })
    end,
    cleanup = real_merge.cleanup,
  }

  require("opencode.apply").start(job, runtime)
  wait_for_state(job, "completed")
  package.loaded["opencode.merge"] = real_merge
  eq(calls, 2)
  eq(logical(fixture.buf), "alpha\nBETA")
  close_fixture(fixture, runtime, { job = job })
end

T["AC-MERGE-05 bounds repeated stale source retries with a typed error"] = function()
  local fixture = open_fixture("alpha\nbeta")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = { kind = "file", path = fixture.path, start_byte = 0, end_byte = #base.text }
  local runtime, job = new_runtime_job(fixture, "merge_05_bound", scope, "ALPHA\nbeta")
  local real_merge = require("opencode.merge")
  local Promise = require("opencode.promise")
  local calls = 0
  package.loaded["opencode.merge"] = {
    run = function()
      calls = calls + 1
      vim.api.nvim_buf_set_text(fixture.buf, 0, 0, 0, 1, { string.char(96 + calls) })
      return Promise.resolve({ kind = "clean", text = job.theirs })
    end,
    cleanup = real_merge.cleanup,
  }

  require("opencode.apply").start(job, runtime)
  wait_for_state(job, "error")
  package.loaded["opencode.merge"] = real_merge
  eq({ calls, job.error_class }, { 4, "stale_source" })
  eq(logical(fixture.buf) == job.theirs, false)
  eq(select(1, require("opencode.snapshot").read_raw(fixture.path)), base.text)
  close_fixture(fixture, runtime, { job = job })
end

T["AC-MERGE-05 rejects a valid but unloaded source buffer"] = function()
  local fixture = open_fixture("alpha\nbeta")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = fragment_range(fixture.path, base.text, "beta")
  local runtime, job = new_runtime_job(fixture, "merge_05_unloaded", scope, "alpha\nBETA")
  vim.cmd.enew()
  vim.cmd("bunload! " .. fixture.buf)
  eq({ vim.api.nvim_buf_is_valid(fixture.buf), vim.api.nvim_buf_is_loaded(fixture.buf) }, { true, false })

  require("opencode.apply").start(job, runtime)
  eq(job.state, "error")
  eq(vim.api.nvim_buf_is_loaded(fixture.buf), false)
  eq(select(1, require("opencode.snapshot").read_raw(fixture.path)), base.text)
  close_fixture(fixture, runtime, { job = job })
end

T["AC-MERGE-06 offers exactly three conflict choices and preserves nonconflicting edits"] = function()
  local fixture = open_fixture("base-one\nbase-two\nbase-three\nbase-four")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = { kind = "file", path = fixture.path, start_byte = 0, end_byte = #base.text }
  local ours = "ours-one\nbase-two\nours-three\nbase-four"
  local theirs = "theirs-one\ntheirs-two\nbase-three\nbase-four"
  local runtime, job = new_runtime_job(fixture, "merge_06", scope, theirs, nil, base)
  vim.api.nvim_buf_set_lines(fixture.buf, 0, -1, false, vim.split(ours, "\n", { plain = true }))
  local old_select = vim.ui.select
  local choices
  vim.ui.select = function(items, _, callback)
    choices = vim.deepcopy(items)
    callback("accept agent changes")
  end
  require("opencode.apply").start(job, runtime)
  wait_for_state(job, "completed")
  vim.ui.select = old_select
  eq(choices, { "keep my changes", "accept agent changes", "open manual diff" })
  eq(logical(fixture.buf), "theirs-one\ntheirs-two\nours-three\nbase-four")
  eq(select(1, require("opencode.snapshot").read_raw(fixture.path)), base.text)
  close_fixture(fixture, runtime, { job = job })
end

T["AC-MERGE-07 exposes manual diff buffers and supports cancel plus confirmed result"] = function()
  local fixture = open_fixture("one\ntwo\nthree")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = { kind = "file", path = fixture.path, start_byte = 0, end_byte = #base.text }
  local runtime, cancelled = new_runtime_job(fixture, "merge_07_cancel", scope, "one\nTWO\nthree")
  require("opencode.job").transition(cancelled, "conflict", {
    session = runtime.sessions[cancelled.session_id],
    conflict_kind = "agent",
    conflict_payload = { base = base, ours = base.text, theirs = cancelled.theirs },
  })
  require("opencode.ui.diff").agent({ id = "manual_cancel", state = "shown" }, runtime, cancelled)
  local result_name = "opencode://manual_cancel/Result"
  eq(
    vim.wait(1000, function()
      return vim.fn.bufnr(result_name) ~= -1
    end),
    true
  )
  local cancel_result = vim.fn.bufnr(result_name)
  for name, editable in pairs({ Base = false, Ours = false, Theirs = false, Result = true }) do
    local buf = vim.fn.bufnr("opencode://manual_cancel/" .. name)
    eq(vim.bo[buf].modifiable, editable, name)
  end
  eq(runtime.sessions[cancelled.session_id].active_job_key, cancelled.key)
  vim.api.nvim_buf_delete(cancel_result, { force = true })
  eq(
    vim.wait(1000, function()
      return cancelled.state == "cancelled"
    end),
    true
  )
  eq(logical(fixture.buf), base.text)

  local runtime_confirmed, confirmed = new_runtime_job(fixture, "merge_07_confirm", scope, "one\nTWO\nthree", nil, base)
  require("opencode.job").transition(confirmed, "conflict", {
    session = runtime_confirmed.sessions[confirmed.session_id],
    conflict_kind = "agent",
    conflict_payload = { base = base, ours = base.text, theirs = confirmed.theirs },
  })
  require("opencode.ui.diff").agent({ id = "manual_confirm", state = "shown" }, runtime_confirmed, confirmed)
  local confirm_name = "opencode://manual_confirm/Result"
  eq(
    vim.wait(1000, function()
      return vim.fn.bufnr(confirm_name) ~= -1
    end),
    true
  )
  local ok
  eq(
    require("opencode.apply").manual(confirmed, runtime_confirmed, "one\nMANUAL\nthree", function(applied)
      ok = applied
    end),
    true
  )
  wait_for_state(confirmed, "completed")
  eq(
    vim.wait(1000, function()
      return ok ~= nil
    end),
    true
  )
  eq(ok, true)
  eq(logical(fixture.buf), "one\nMANUAL\nthree")
  eq(select(1, require("opencode.snapshot").read_raw(fixture.path)), base.text)
  for _, prefix in ipairs({
    "manual_confirm/Base",
    "manual_confirm/Ours",
    "manual_confirm/Theirs",
    "manual_confirm/Result",
  }) do
    local buf = vim.fn.bufnr("opencode://" .. prefix)
    if buf ~= -1 and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  close_fixture(fixture, runtime_confirmed, { cancelled = cancelled, confirmed = confirmed })
  vim.fn.delete(runtime.temp_root, "rf")
end

T["AC-MERGE-07 keeps manual conflict results inside the current scope"] = function()
  local fixture = open_fixture("alpha\nbeta\ngamma")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = fragment_range(fixture.path, base.text, "beta")
  local runtime, job = new_runtime_job(fixture, "merge_07_scope", scope, "alpha\nBETA\ngamma")
  require("opencode.job").transition(job, "conflict", {
    session = runtime.sessions[job.session_id],
    conflict_kind = "agent",
    conflict_payload = { base = base, ours = base.text, theirs = job.theirs },
  })
  local callback_error

  eq(
    require("opencode.apply").manual(job, runtime, "ALPHA\nBETA\ngamma", function(_, err)
      callback_error = err
    end),
    true
  )
  eq(
    vim.wait(1000, function()
      return callback_error ~= nil
    end),
    true
  )
  eq({ callback_error, job.state, logical(fixture.buf) }, { "scope_violation", "conflict", base.text })

  eq(require("opencode.apply").manual(job, runtime, "alpha\nBETA\ngamma"), true)
  wait_for_state(job, "completed")
  eq(logical(fixture.buf), "alpha\nBETA\ngamma")
  close_fixture(fixture, runtime, { job = job })
end

T["AC-MERGE-08 applies one minimal undoable span without writing or reloading"] = function()
  local fixture = open_fixture("one\ntwo\nthree")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = { kind = "file", path = fixture.path, start_byte = 0, end_byte = #base.text }
  local runtime, job = new_runtime_job(fixture, "merge_08", scope, "one\nTWO\nthree")
  vim.api.nvim_win_set_cursor(0, { 2, 1 })
  local before_cursor = vim.api.nvim_win_get_cursor(0)
  local real_set_text = vim.api.nvim_buf_set_text
  local calls, mutation = 0, nil
  vim.api.nvim_buf_set_text = function(...)
    calls = calls + 1
    mutation = { select(2, ...) }
    return real_set_text(...)
  end
  require("opencode.apply").start(job, runtime)
  wait_for_state(job, "completed")
  vim.api.nvim_buf_set_text = real_set_text
  eq(calls, 1)
  eq(mutation, { 0, 1, 0, 3, { "TWO" } })
  eq(logical(fixture.buf), "one\nTWO\nthree")
  eq(vim.api.nvim_win_get_cursor(0), before_cursor)
  eq(select(1, require("opencode.snapshot").read_raw(fixture.path)), base.text)
  vim.cmd.undo()
  eq(logical(fixture.buf), base.text)
  close_fixture(fixture, runtime, { job = job })
end

T["AC-MERGE-09 reports external disk change and blocks retry until reconciliation"] = function()
  local fixture = open_fixture("one\ntwo")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = fragment_range(fixture.path, base.text, "two")
  local runtime, job = new_runtime_job(fixture, "merge_09", scope, "one\nTWO")
  local before = logical(fixture.buf)
  local old_select = vim.ui.select
  local choices, select_callback
  local dialog_count = 0
  vim.ui.select = function(items, _, callback)
    dialog_count = dialog_count + 1
    choices = vim.deepcopy(items)
    select_callback = callback
  end
  vim.fn.writefile({ "external", "disk" }, fixture.path)
  require("opencode.apply").start(job, runtime)
  eq(job.state, "conflict")
  eq(job.conflict_kind, "external_change")
  eq(logical(fixture.buf), before)
  eq(select(1, require("opencode.snapshot").read_raw(fixture.path)), "external\ndisk\n")
  local retry_error
  eq(
    require("opencode.apply").retry(job, runtime, function(_, err)
      retry_error = err
    end),
    false
  )
  eq(retry_error, "external_change")
  eq(
    vim.wait(1000, function()
      return choices ~= nil
    end),
    true
  )
  eq(choices, { "open external diff", "retry apply", "cancel" })
  select_callback("retry apply")
  eq(
    vim.wait(1000, function()
      return dialog_count == 2
    end),
    true
  )
  vim.wait(20)
  eq(dialog_count, 2)
  vim.ui.select = old_select
  eq(logical(fixture.buf), before)
  require("opencode.job").transition(job, "cancelled", { session = runtime.sessions[job.session_id] })
  close_fixture(fixture, runtime, { job = job })
end

T["AC-MERGE-10 merges a saved Ours buffer when disk equals Ours"] = function()
  local fixture = open_fixture("alpha\nbeta")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = fragment_range(fixture.path, base.text, "beta")
  local runtime, job = new_runtime_job(fixture, "merge_10", scope, "alpha\nBETA", nil, base)
  local ours = "ALPHA\nbeta"
  vim.api.nvim_buf_set_lines(fixture.buf, 0, -1, false, vim.split(ours, "\n", { plain = true }))
  vim.cmd.write()
  require("opencode.apply").start(job, runtime)
  wait_for_state(job, "completed")
  eq(logical(fixture.buf), "ALPHA\nBETA")
  eq(select(1, require("opencode.snapshot").read_raw(fixture.path)), "ALPHA\nbeta\n")
  close_fixture(fixture, runtime, { job = job })
end

T["AC-MERGE-11 rechecks disk after merge and rejects a stale result"] = function()
  local fixture = open_fixture("one\ntwo")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = fragment_range(fixture.path, base.text, "two")
  local runtime, job = new_runtime_job(fixture, "merge_11", scope, "one\nTWO")
  local real_merge = require("opencode.merge")
  local Promise = require("opencode.promise")
  local tick = vim.api.nvim_buf_get_changedtick(fixture.buf)
  local old_select = vim.ui.select
  local dialog_shown = false
  vim.ui.select = function()
    dialog_shown = true
  end
  package.loaded["opencode.merge"] = {
    run = function()
      return Promise.resolve({ kind = "clean", text = job.theirs })
    end,
    cleanup = real_merge.cleanup,
  }
  require("opencode.apply").start(job, runtime)
  vim.schedule(function()
    local handle = assert(vim.uv.fs_open(fixture.path, "w", 420))
    assert(vim.uv.fs_write(handle, "race\ndisk\n", 0))
    vim.uv.fs_close(handle)
  end)
  eq(
    vim.wait(1000, function()
      return job.state == "conflict" and dialog_shown
    end),
    true
  )
  package.loaded["opencode.merge"] = real_merge
  vim.ui.select = old_select
  eq(job.conflict_kind, "external_change")
  eq(logical(fixture.buf), base.text)
  eq(vim.api.nvim_buf_get_changedtick(fixture.buf), tick)
  eq(select(1, require("opencode.snapshot").read_raw(fixture.path)), "race\ndisk\n")
  require("opencode.job").transition(job, "cancelled", { session = runtime.sessions[job.session_id] })
  close_fixture(fixture, runtime, { job = job })
end

T["AC-MERGE-12 preserves EOL metadata and distinguishes empty trailing lines"] = function()
  local cases = {
    { raw = "one\ntwo\n", replacement = "ONE\nTWO", expected = "one\ntwo" },
    { raw = "one\r\ntwo\r\n", replacement = "ONE\nTWO", expected = "one\ntwo" },
    { raw = "one", replacement = "TWO", expected = "one" },
    { raw = "", replacement = "new", expected = "" },
    { raw = "one\n\n", replacement = "two\n", expected = "one\n" },
  }
  for index, case in ipairs(cases) do
    local fixture = open_fixture(case.raw)
    local snapshot = require("opencode.snapshot")
    local base = assert(snapshot.capture(fixture.buf))
    eq(base.text, case.expected, "case " .. index)
    local options = { fileformat = base.fileformat, endofline = base.endofline, fixendofline = base.fixendofline }
    local scope = { kind = "file", path = fixture.path, start_byte = 0, end_byte = #base.text }
    local runtime, job = new_runtime_job(fixture, "merge_12_" .. index, scope, case.replacement)
    require("opencode.apply").start(job, runtime)
    wait_for_state(job, "completed")
    eq(logical(fixture.buf), case.replacement, "case " .. index)
    eq(
      { vim.bo[fixture.buf].fileformat, vim.bo[fixture.buf].endofline, vim.bo[fixture.buf].fixendofline },
      { options.fileformat, options.endofline, options.fixendofline },
      "case " .. index
    )
    eq(select(1, snapshot.read_raw(fixture.path)), case.raw, "case " .. index)
    close_fixture(fixture, runtime, { job = job })
  end

  local fixture = open_fixture("one")
  local base = assert(require("opencode.snapshot").capture(fixture.buf))
  local scope = { kind = "file", path = fixture.path, start_byte = 0, end_byte = #base.text }
  local runtime, job = new_runtime_job(fixture, "merge_12_cr", scope, "bad\rtext")
  local proposal, err = require("opencode.proposal").validate({
    replacement = "bad\rtext",
    summary = "invalid EOL",
  }, job)
  eq(proposal, nil)
  eq(err.error_class, "invalid_structured_output")
  eq(logical(fixture.buf), base.text)
  close_fixture(fixture, runtime, { job = job })
end

T["AC-MERGE-12 completes partial private writes and removes every operand"] = function()
  local merge = require("opencode.merge")
  local directory = vim.fn.tempname()
  local real_write = vim.uv.fs_write
  local write_calls, result = 0, nil
  vim.uv.fs_write = function(handle, text, offset)
    write_calls = write_calls + 1
    local length = math.max(1, math.floor(#text / 2))
    return real_write(handle, text:sub(1, length), offset)
  end
  merge
    .run("base contents", "ours contents", "theirs contents", {
      temp_dir = directory,
      owner_key = "partial-write",
      runner = function(command, _, callback)
        eq(select(1, require("opencode.snapshot").read_raw(command[#command - 2])), "ours contents")
        eq(select(1, require("opencode.snapshot").read_raw(command[#command - 1])), "base contents")
        eq(select(1, require("opencode.snapshot").read_raw(command[#command])), "theirs contents")
        callback({ code = 0, signal = 0, stdout = "merged contents" })
      end,
    })
    :next(function(value)
      result = value
    end)
  vim.uv.fs_write = real_write

  eq(
    vim.wait(1000, function()
      return result ~= nil
    end),
    true
  )
  eq(result, { kind = "clean", text = "merged contents" })
  eq(write_calls > 3, true)
  eq(vim.fn.glob(directory .. "/*", false, true), {})
  eq(merge.active["partial-write"], nil)
  vim.fn.delete(directory, "rf")
end

T["AC-JOB-03 applies two non-overlapping Jobs in either order without disk or worktree changes"] = function()
  local orders = { { "alpha", "beta" }, { "beta", "alpha" } }
  for index, order in ipairs(orders) do
    local original = "local function alpha()\n  return 1\nend\n\nlocal function beta()\n  return 2\nend"
    local fixture = open_fixture(original)
    local base = assert(require("opencode.snapshot").capture(fixture.buf))
    local alpha = fragment_range(fixture.path, base.text, "return 1")
    local beta = fragment_range(fixture.path, base.text, "return 2")
    local runtime = require("opencode.runtime").new(fixture.root)
    runtime.generation, runtime.temp_root = 1, vim.fn.tempname()
    vim.fn.mkdir(runtime.temp_root, "p")
    require("opencode.runtime").registry[runtime.root] = runtime
    local first_scope = order[1] == "alpha" and alpha or beta
    local second_scope = order[2] == "alpha" and alpha or beta
    local first_theirs = order[1] == "alpha" and original:gsub("return 1", "return 10", 1)
      or original:gsub("return 2", "return 20", 1)
    local second_theirs = order[2] == "alpha" and original:gsub("return 1", "return 10", 1)
      or original:gsub("return 2", "return 20", 1)
    local first = {
      key = "job_" .. index .. "_first",
      root = fixture.root,
      session_id = "session_" .. index .. "_first",
      mode = "build",
      state = "pending_apply",
      buffer = fixture.buf,
      path = fixture.path,
      base = base,
      scope = first_scope,
      marks = require("opencode.scope").create_marks(fixture.buf, first_scope),
      theirs = first_theirs,
    }
    local second = {
      key = "job_" .. index .. "_second",
      root = fixture.root,
      session_id = "session_" .. index .. "_second",
      mode = "build",
      state = "pending_apply",
      buffer = fixture.buf,
      path = fixture.path,
      base = base,
      scope = second_scope,
      marks = require("opencode.scope").create_marks(fixture.buf, second_scope),
      theirs = second_theirs,
    }
    runtime.sessions[first.session_id] = { id = first.session_id, active_job_key = first.key }
    runtime.sessions[second.session_id] = { id = second.session_id, active_job_key = second.key }
    runtime.jobs[first.key], runtime.jobs[second.key] = first, second
    require("opencode.apply").start(first, runtime)
    wait_for_state(first, "completed")
    local remaining = assert(require("opencode.scope").current_range(second))
    eq(logical(fixture.buf):sub(remaining.start_byte + 1, remaining.end_byte), order[2] == "alpha" and "1" or "2")
    require("opencode.apply").start(second, runtime)
    wait_for_state(second, "completed")
    eq(logical(fixture.buf), original:gsub("return 1", "return 10", 1):gsub("return 2", "return 20", 1))
    eq(select(1, require("opencode.snapshot").read_raw(fixture.path)), original)
    eq(vim.fn.glob(runtime.temp_root .. "/*", false, true), {})
    eq(vim.fn.isdirectory(fixture.root .. "/.git"), 0)
    close_fixture(fixture, runtime, { first = first, second = second })
  end
end

return T
