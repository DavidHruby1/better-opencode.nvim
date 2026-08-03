---@diagnostic disable: duplicate-set-field, need-check-nil

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["active location is injected exactly once"] = function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "local x = 1" }, path)
  vim.cmd.edit(path)
  local capture = assert(require("opencode.context").capture())
  local context = require("opencode.context").new(capture, { root = vim.fs.dirname(path) })
  local rendered = context:render("Explain @this").plaintext
  local location = require("opencode.context.builtins").this(context)
  local _, count = rendered:gsub(vim.pesc(location), "")
  eq(count, 1)
  vim.uv.fs_unlink(path)
end

T["unsupported unnamed buffer fails before Runtime"] = function()
  vim.cmd.enew()
  eq(select(2, require("opencode.context").capture()), "unnamed_buffer")
end

T["context file read failure returns disk_read"] = function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "read me" }, path)
  vim.cmd.edit(path)
  local snapshot = require("opencode.snapshot")
  local old_read_raw = snapshot.read_raw
  snapshot.read_raw = function()
    return nil
  end
  local capture, error = require("opencode.context").capture()
  snapshot.read_raw = old_read_raw
  eq({ capture, error }, { nil, "disk_read" })
  vim.cmd.bwipeout({ bang = true })
  vim.uv.fs_unlink(path)
end

T["preview restores references when a provider throws"] = function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "source" }, path)
  vim.cmd.edit(path)
  local buf = vim.api.nvim_get_current_buf()
  local context = require("opencode.context").new(assert(require("opencode.context").capture()), {
    root = vim.fs.dirname(path),
  })
  local references = { [buf] = true }
  context.referenced_buffers = references

  local config = require("opencode.config")
  local old_provider = config.opts.contexts["@throws"]
  config.opts.contexts["@throws"] = function(current)
    current.referenced_buffers[buf] = false
    error("provider_failed")
  end
  local ok, err = pcall(context.preview, context, "@throws")
  config.opts.contexts["@throws"] = old_provider

  eq(ok, false)
  eq(err, "provider_failed")
  eq(context.referenced_buffers == references, true)
  eq(context.referenced_buffers[buf], true)
  vim.cmd.bwipeout({ bang = true })
  vim.uv.fs_unlink(path)
end

T["render maps a wiped dirty buffer to write_failed"] = function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "before" }, path)
  vim.cmd.edit(path)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "dirty" })
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = buf,
    once = true,
    callback = function()
      vim.api.nvim_buf_delete(buf, { force = true, wipe = true })
    end,
  })
  local context = require("opencode.context").new(assert(require("opencode.context").capture()), {
    root = vim.fs.dirname(path),
  })

  local ok, err = pcall(context.render, context, "render")

  eq(ok, false)
  eq(type(err), "table")
  eq(err.error_class, "write_failed")
  eq(vim.api.nvim_buf_is_valid(buf), false)
  vim.uv.fs_unlink(path)
end

T["extmark scope tracks insertion with configured gravity"] = function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha", "beta" })
  local scope = { start_byte = 6, end_byte = 10 }
  local marks = require("opencode.scope").create_marks(buf, scope)
  local mark = vim.api.nvim_buf_get_extmark_by_id(buf, require("opencode.scope").namespace, marks.start_id, {
    details = true,
  })
  eq(mark[3].hl_group, "OpencodeScope")
  local job = { buffer = buf, marks = marks }
  vim.api.nvim_buf_set_text(buf, 0, 0, 0, 0, { "prefix", "" })
  local current = require("opencode.scope").current_range(job)
  eq({ current.start_byte, current.end_byte }, { 13, 17 })
  require("opencode.scope").delete_marks(job)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["visual scope rejects formatting that collapses its tracked range"] = function()
  local path = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({ "local function alpha()", "  return 1", "end" }, path)
  vim.cmd.edit(path)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "  return 10" })
  local capture = assert(require("opencode.context").capture({
    from = { 2, 2 },
    to = { 2, 10 },
    kind = "char",
  }))
  local context = require("opencode.context").new(capture, { root = vim.fs.dirname(path) })
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = buf,
    once = true,
    callback = function()
      vim.api.nvim_buf_set_text(buf, 1, 2, 1, 11, {})
    end,
  })

  local ok, err = pcall(context.render, context, "change it")
  eq(ok, false)
  eq(type(err) == "table" and err.error_class, "scope_changed")
  eq(vim.bo[buf].modified, false)

  vim.cmd.bwipeout({ bang = true })
  vim.uv.fs_unlink(path)
end

T["non-modifiable source terminates apply without throwing"] = function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "one" }, path)
  vim.cmd.edit(path)
  local buf = vim.api.nvim_get_current_buf()
  local base = assert(require("opencode.snapshot").capture(buf))
  local session = { id = "ses_readonly", active_job_key = "job_readonly" }
  local job = {
    key = session.active_job_key,
    root = vim.fs.dirname(path),
    session_id = session.id,
    mode = "build",
    state = "pending_apply",
    buffer = buf,
    path = path,
    base = base,
    scope = { kind = "file", path = path, start_byte = 0, end_byte = #base.text },
    theirs = "two",
  }
  job.marks = require("opencode.scope").create_marks(buf, job.scope)
  vim.bo[buf].modifiable = false
  require("opencode.apply").start(job, { sessions = { [session.id] = session }, jobs = { [job.key] = job } })
  eq(job.state, "error")
  vim.bo[buf].modifiable = true
  vim.cmd.bwipeout({ bang = true })
  vim.uv.fs_unlink(path)
end

T["clean merge applies once without writing disk and one undo restores Ours"] = function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "one", "two", "three" }, path)
  vim.cmd.edit(path)
  local buf = vim.api.nvim_get_current_buf()
  local base = assert(require("opencode.snapshot").capture(buf))
  local scope = { kind = "range", path = path, start_byte = 4, end_byte = 7 }
  local marks = require("opencode.scope").create_marks(buf, scope)
  local session = { id = "ses_apply", active_job_key = "job" }
  local job = {
    key = "job",
    session_id = session.id,
    mode = "build",
    state = "pending_apply",
    buffer = buf,
    path = path,
    base = base,
    scope = scope,
    marks = marks,
    theirs = "one\nTWO\nthree",
  }
  local runtime = { sessions = { [session.id] = session }, jobs = { [job.key] = job } }
  require("opencode.apply").start(job, runtime)
  eq(
    vim.wait(1000, function()
      return job.state ~= "pending_apply"
    end),
    true
  )
  eq(job.state, "completed")
  eq(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), job.theirs or "one\nTWO\nthree")
  eq(table.concat(vim.fn.readfile(path), "\n"), "one\ntwo\nthree")
  eq(vim.bo[buf].modified, true)
  vim.cmd.undo()
  eq(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "one\ntwo\nthree")
  vim.cmd.bwipeout({ bang = true })
  vim.uv.fs_unlink(path)
end

T["disk races block every automatic and conflict apply path"] = function()
  local real_merge = package.loaded["opencode.merge"] or require("opencode.merge")
  local function delayed_merge(result)
    package.loaded["opencode.merge"] = {
      run = function()
        return require("opencode.promise").new(function(resolve)
          vim.defer_fn(function()
            resolve(result)
          end, 10)
        end)
      end,
      cleanup = function() end,
    }
  end
  local function fixture(state, kind)
    local path = vim.fn.tempname()
    vim.fn.writefile({ "one", "two", "three" }, path)
    vim.cmd.edit(path)
    local buf = vim.api.nvim_get_current_buf()
    local base = assert(require("opencode.snapshot").capture(buf))
    local scope = { kind = "range", path = path, start_byte = 4, end_byte = 7 }
    local marks = require("opencode.scope").create_marks(buf, scope)
    local session = { id = "ses_race", active_job_key = "job" }
    local job = {
      key = "job",
      root = vim.fs.dirname(path),
      session_id = session.id,
      mode = "build",
      state = state,
      conflict_kind = kind,
      conflict_payload = kind == "agent" and { base = base, ours = base.text, theirs = "one\nTWO\nthree" } or {},
      buffer = buf,
      path = path,
      base = base,
      scope = scope,
      marks = marks,
      theirs = "one\nTWO\nthree",
    }
    local runtime =
      { root = job.root, generation = 1, sessions = { [session.id] = session }, jobs = { [job.key] = job } }
    return path, buf, job, runtime
  end
  local function cleanup(path, buf, job)
    require("opencode.scope").delete_marks(job)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    vim.uv.fs_unlink(path)
  end

  for _, route in ipairs({ "automatic", "prefer", "manual", "retry" }) do
    local state = route == "automatic" and "pending_apply" or "conflict"
    local kind = route == "retry" and "external_change" or "agent"
    local path, buf, job, runtime = fixture(state, kind)
    local callback_error
    if route == "automatic" then
      delayed_merge({ kind = "clean", text = job.theirs })
      require("opencode.apply").start(job, runtime)
    elseif route == "prefer" then
      delayed_merge({ kind = "clean", text = job.theirs })
      require("opencode.apply").prefer(job, runtime, "theirs", function(_, err)
        callback_error = err
      end)
    elseif route == "manual" then
      require("opencode.apply").manual(job, runtime, job.theirs, function(_, err)
        callback_error = err
      end)
      runtime.generation = runtime.generation + 1
    else
      delayed_merge({ kind = "clean", text = job.theirs })
      require("opencode.apply").retry(job, runtime, function(_, err)
        callback_error = err
      end)
    end
    vim.fn.writefile({ "external", "change" }, path)
    eq(
      vim.wait(500, function()
        return route == "automatic" and job.state ~= "pending_apply" or callback_error ~= nil
      end),
      true,
      route
    )
    eq(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "one\ntwo\nthree", route)
    if route == "automatic" then
      eq({ job.state, job.conflict_kind }, { "conflict", "external_change" }, route)
    else
      eq(job.state, "conflict", route)
      eq(
        callback_error == "external_change" or callback_error == "stale_source" or callback_error == "stale_generation",
        true,
        route
      )
    end
    cleanup(path, buf, job)
  end
  package.loaded["opencode.merge"] = real_merge
end

---Starts both merges before resolving either one, then proves the stale loser retries without saving the file.
---The queued merge boundary makes both process completion orders deterministic and counts each terminal notification.
T["two non-overlapping Jobs apply concurrently in either completion order"] = function()
  local orders = { { "a", "b" }, { "b", "a" } }
  for _, order in ipairs(orders) do
    local path = vim.fn.tempname()
    local original = "local function alpha()\n  return 1\nend\n\nlocal function beta()\n  return 2\nend"
    vim.fn.writefile(vim.split(original, "\n", { plain = true }), path)
    vim.cmd.edit(path)
    local buf = vim.api.nvim_get_current_buf()
    local base = assert(require("opencode.snapshot").capture(buf))
    local alpha = assert(original:find("1", 1, true)) - 1
    local beta = assert(original:find("2", 1, true)) - 1
    local scopes = {
      a = { kind = "range", path = path, start_byte = alpha, end_byte = alpha + 1 },
      b = { kind = "range", path = path, start_byte = beta, end_byte = beta + 1 },
    }
    local runtime = { root = vim.fs.dirname(path), generation = 1, sessions = {}, jobs = {} }
    local jobs = {}
    for name, replacement in pairs({ a = "10", b = "20" }) do
      local session_id = "ses_" .. name
      local session = { id = session_id, active_job_key = "job_" .. name }
      local scope = scopes[name]
      local theirs = original:sub(1, scope.start_byte) .. replacement .. original:sub(scope.end_byte + 1)
      local job = {
        key = session.active_job_key,
        root = runtime.root,
        session_id = session_id,
        user_message_id = "msg_" .. name,
        mode = "build",
        state = "pending_apply",
        buffer = buf,
        path = path,
        base = base,
        scope = scope,
        marks = require("opencode.scope").create_marks(buf, scope),
        theirs = theirs,
      }
      job.runtime = runtime
      runtime.sessions[session_id], runtime.jobs[job.key], jobs[name] = session, job, job
    end
    local Promise = require("opencode.promise")
    local pending_merges = {}
    local real_merge = package.loaded["opencode.merge"] or require("opencode.merge")
    package.loaded["opencode.merge"] = {
      run = function(_, _, theirs)
        local promise = Promise.new(function(resolve)
          table.insert(pending_merges, { resolve = resolve, theirs = theirs, resolved = false })
        end)
        return promise
      end,
      cleanup = function() end,
    }
    local notify = require("opencode.ui.notify")
    local real_emit = notify.emit
    local completed_notifications = {}
    notify.emit = function(kind, metadata, current_runtime)
      if kind == "completed" then
        table.insert(completed_notifications, metadata.job_key)
      end
      return real_emit(kind, metadata, current_runtime)
    end
    local function resolve_merge(name)
      local theirs = jobs[name].theirs
      for _, merge in ipairs(pending_merges) do
        if not merge.resolved and merge.theirs == theirs then
          merge.resolved = true
          merge.resolve({ kind = "clean", text = theirs })
          return
        end
      end
      error("missing pending merge for " .. name)
    end
    local function wait_for_state(job, state)
      eq(vim.wait(1000, function()
        return job.state == state
      end), true)
    end

    require("opencode.apply").start(jobs[order[1]], runtime)
    require("opencode.apply").start(jobs[order[2]], runtime)
    eq(#pending_merges, 2)

    resolve_merge(order[1])
    resolve_merge(order[2])
    wait_for_state(jobs[order[1]], "completed")
    eq(vim.wait(1000, function()
      return #pending_merges == 3
    end), true)
    resolve_merge(order[2])
    wait_for_state(jobs[order[2]], "completed")

    eq(
      table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
      original:gsub("1", "10", 1):gsub("2", "20", 1)
    )
    eq(table.concat(vim.fn.readfile(path), "\n"), original)
    eq(#completed_notifications, 2)
    eq(completed_notifications[1] ~= completed_notifications[2], true)
    notify.emit = real_emit
    package.loaded["opencode.merge"] = real_merge
    vim.cmd.undo()
    vim.cmd.undo()
    eq(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), original)
    vim.cmd.bwipeout({ bang = true })
    vim.uv.fs_unlink(path)
  end
end

T["all-active scope validation rejects overlap and collapse"] = function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcdefghij" })
  local function job(key, start_byte, end_byte)
    local scope = { start_byte = start_byte, end_byte = end_byte }
    return {
      key = key,
      mode = "build",
      state = "running",
      buffer = buf,
      scope = scope,
      marks = require("opencode.scope").create_marks(buf, scope),
    }
  end
  local a, b = job("a", 1, 5), job("b", 4, 8)
  local runtime = { jobs = { a = a, b = b } }
  eq(select(2, require("opencode.scope").active_ranges(runtime, buf)), "scope_overlap")
  require("opencode.scope").delete_marks(b)
  b.marks = require("opencode.scope").create_marks(buf, { start_byte = 8, end_byte = 8 })
  b.scope = { start_byte = 4, end_byte = 8 }
  eq(select(2, require("opencode.scope").active_ranges(runtime, buf)), "scope_overlap")
  require("opencode.scope").delete_marks(a)
  require("opencode.scope").delete_marks(b)
  vim.api.nvim_buf_delete(buf, { force = true })
end

return T
