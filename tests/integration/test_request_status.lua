---@diagnostic disable: duplicate-set-field

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local Job = require("opencode.job")
local request_status = require("opencode.ui.request_status")
local scope = require("opencode.scope")

---Installs a timer double whose callback runs only when the case explicitly fires it.
---The restore function returns Neovim's timer and scheduling globals to their prior values.
local function controlled_timer()
  local old_new_timer, old_schedule_wrap = vim.uv.new_timer, vim.schedule_wrap
  local timers = {}
  vim.uv.new_timer = function()
    local timer = { closed = false, callback = nil, stopped = false }
    function timer:start(_, _, callback)
      self.callback = callback
    end
    function timer:stop()
      self.stopped = true
    end
    function timer:is_closing()
      return self.closed
    end
    function timer:close()
      self.closed = true
    end
    function timer:fire()
      self.callback()
    end
    table.insert(timers, timer)
    return timer
  end
  vim.schedule_wrap = function(callback)
    return callback
  end
  return function()
    vim.uv.new_timer, vim.schedule_wrap = old_new_timer, old_schedule_wrap
  end, function()
    return timers[1]
  end
end

---Returns the status extmark's virtual lines, which are the visible inline Build display.
local function rendered_lines(buf, status)
  local namespace = vim.api.nvim_get_namespaces()["opencode-build-request-status"]
  local mark = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, status.extmark_id, { details = true })
  return mark[3] and mark[3].virt_lines or {}
end

---Creates a Build Job in a real current buffer and removes its buffer, marks, and timer after the case.
---The scope is supplied in bytes so the same helper covers range and function anchors.
local function with_job(lines, scope_data, callback)
  local restore_timer, get_timer = controlled_timer()
  local old_buf = vim.api.nvim_get_current_buf()
  local old_width = vim.api.nvim_win_get_width(0)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  local job = Job.new("ses_status", {
    root = "/request-status",
    buf = buf,
    path = "/request-status/file.lua",
    mode = "build",
    scope = scope_data,
    marks = scope.create_marks(buf, scope_data),
  })
  local ok, failure = xpcall(function()
    callback(job, buf, get_timer())
  end, debug.traceback)
  request_status.cleanup(job.request_status)
  scope.delete_marks(job)
  vim.api.nvim_win_set_width(0, old_width)
  vim.api.nvim_set_current_buf(old_buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  restore_timer()
  assert(ok, failure)
end

T["AC-UI-05 Build status is inline, spinner-only before reasoning, and opens no window"] = function()
  local windows = #vim.api.nvim_list_wins()
  local current = vim.api.nvim_get_current_win()
  with_job(
    { "function target()", "  return true", "end" },
    { kind = "function", start_byte = 0, end_byte = 1 },
    function(job, buf, timer)
      timer:fire()
      eq(#vim.api.nvim_list_wins(), windows)
      eq(vim.api.nvim_get_current_win(), current)
      eq(#rendered_lines(buf, job.request_status), 1)
      eq(rendered_lines(buf, job.request_status)[1][1][1], "⠙ Implementing")
      request_status.replace_reasoning(job.request_status, "ses_status", "assistant_status", "part_status", "thinking")
      eq(#rendered_lines(buf, job.request_status), 2)
    end
  )
end

T["status anchor follows inserted lines before a function scope"] = function()
  with_job(
    { "before", "function target()", "  return true", "end", "after" },
    { kind = "function", start_byte = #"before\n", end_byte = #"before\nfunction target()" },
    function(job, buf)
      local before = vim.api.nvim_buf_get_extmark_by_id(
        buf,
        vim.api.nvim_get_namespaces()["opencode-build-request-status"],
        job.request_status.extmark_id,
        {}
      )
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "prefix", "" })
      request_status.replace_reasoning(job.request_status, "ses_status", "assistant_status", "part_status", "moved")
      local after = vim.api.nvim_buf_get_extmark_by_id(
        buf,
        vim.api.nvim_get_namespaces()["opencode-build-request-status"],
        job.request_status.extmark_id,
        {}
      )
      eq({ before[1], after[1] }, { 1, 3 })
      eq(rendered_lines(buf, job.request_status)[2][1][1], "  moved")
    end
  )
end

T["terminal and conflict transitions safely remove inline status resources"] = function()
  for _, state in ipairs({ "completed", "cancelled", "error", "scope_violation", "conflict" }) do
    with_job({ "target" }, { kind = "range", start_byte = 0, end_byte = 1 }, function(job, buf, timer)
      local namespace = vim.api.nvim_get_namespaces()["opencode-build-request-status"]
      local extmark_id = job.request_status.extmark_id
      local session = { id = job.session_id, active_job_key = job.key }
      if state == "conflict" then
        job.state = "pending_apply"
      end
      local attrs = state == "conflict"
          and {
            session = session,
            conflict_kind = "agent",
            conflict_payload = { base = {}, ours = "", theirs = "" },
          }
        or { session = session }
      eq(require("opencode.job").transition(job, state, attrs), true, state)
      eq({ job.state, job.request_status, timer.stopped, timer.closed }, { state, nil, true, true }, state)
      eq(#vim.api.nvim_buf_get_extmark_by_id(buf, namespace, extmark_id, {}), 0, state)
    end)
  end
end

T["successful public apply keeps the replacement in one undo step"] = function()
  local restore_timer, get_timer = controlled_timer()
  local old_buf = vim.api.nvim_get_current_buf()
  local old_width = vim.api.nvim_win_get_width(0)
  local path = vim.fn.tempname()
  vim.fn.writefile({ "one", "two", "three" }, path)
  vim.cmd.edit(path)
  local buf = vim.api.nvim_get_current_buf()
  local root = vim.fs.dirname(path)
  local base = assert(require("opencode.snapshot").capture(buf))
  local scope_data = { kind = "range", path = path, start_byte = 4, end_byte = 7 }
  local session = { id = "ses_apply_status" }
  local job = Job.new(session.id, {
    root = root,
    buf = buf,
    path = path,
    mode = "build",
    scope = scope_data,
    marks = scope.create_marks(buf, scope_data),
    base = base,
  })
  job.state, job.theirs = "pending_apply", "one\nTWO\nthree"
  session.active_job_key = job.key
  local runtime = require("opencode.runtime").new(root)
  runtime.sessions[session.id], runtime.jobs[job.key] = session, job
  local ok, failure = xpcall(function()
    require("opencode.apply").start(job, runtime)
    eq(
      vim.wait(1000, function()
        return job.state ~= "pending_apply"
      end),
      true
    )
    eq(job.state, "completed")
    vim.cmd.undo()
    eq(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "one\ntwo\nthree")
  end, debug.traceback)
  request_status.cleanup(job.request_status)
  scope.delete_marks(job)
  vim.api.nvim_win_set_width(0, old_width)
  vim.api.nvim_set_current_buf(old_buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.fn.delete(path)
  restore_timer()
  assert(ok, failure)
  eq(get_timer().closed, true)
end

return T
