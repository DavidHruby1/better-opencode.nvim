---@diagnostic disable: duplicate-set-field

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local request_status = require("opencode.ui.request_status")
local scope = require("opencode.scope")

T["Plan Jobs do not create the transient Build request status"] = function()
  local job = require("opencode.job").new("ses_plan", {
    root = "/request-status",
    buf = vim.api.nvim_create_buf(true, true),
    path = "/request-status/file.lua",
    mode = "plan",
  })
  eq(job.request_status, nil)
  vim.api.nvim_buf_delete(job.buffer, { force = true })
end

---Installs a synchronous timer double so status redraws are driven only by the test.
---The returned restore function puts both replaced Neovim globals back after the case.
local function controlled_timer()
  local old_new_timer, old_schedule_wrap = vim.uv.new_timer, vim.schedule_wrap
  local timers = {}
  vim.uv.new_timer = function()
    local timer = {
      closed = false,
      callback = nil,
      stopped = false,
    }
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

---Reads the transient lines from the status extmark as a user-visible rendered value.
---The test deliberately avoids inspecting the module's private reasoning table.
local function rendered_lines(buf, status)
  local namespace = vim.api.nvim_get_namespaces()["opencode-build-request-status"]
  local mark = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, status.extmark_id, { details = true })
  return mark[3] and mark[3].virt_lines or {}
end

---Creates one real source buffer and Build scope, then removes every mark and timer afterward.
---The callback can exercise the public status methods without leaving global or buffer state behind.
local function with_status(callback)
  local restore_timer, get_timer = controlled_timer()
  local old_buf = vim.api.nvim_get_current_buf()
  local old_width = vim.api.nvim_win_get_width(0)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "function target()", "  return true", "end" })
  vim.api.nvim_set_current_buf(buf)
  local job = {
    buffer = buf,
    marks = scope.create_marks(buf, { start_byte = 0, end_byte = 1 }),
  }
  local status = request_status.new(job)
  local ok, failure = xpcall(function()
    callback(status, job, buf, get_timer())
  end, debug.traceback)
  request_status.cleanup(status)
  scope.delete_marks(job)
  vim.api.nvim_win_set_width(0, old_width)
  vim.api.nvim_set_current_buf(old_buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  restore_timer()
  assert(ok, failure)
end

T["Build status starts with one spinner line and full updates replace reasoning"] = function()
  with_status(function(status, _, buf)
    eq(#rendered_lines(buf, status), 1)
    request_status.replace_reasoning(status, "ses_1", "assistant_1", "part_1", "first full text")
    eq(#rendered_lines(buf, status), 2)
    eq(rendered_lines(buf, status)[2][1][1], "  first full text")
    request_status.replace_reasoning(status, "ses_1", "assistant_1", "part_1", "second full text")
    eq(rendered_lines(buf, status)[2][1][1], "  second full text")
    eq(rendered_lines(buf, status)[2][1][1]:find("first", 1, true), nil)
  end)
end

T["registered deltas append while delta-first and unknown parts stay hidden"] = function()
  with_status(function(status, _, buf)
    request_status.append_reasoning(status, "ses_1", "assistant_1", "part_1", " ignored")
    eq(#rendered_lines(buf, status), 1)
    request_status.replace_reasoning(status, "ses_1", "assistant_1", "part_1", "full")
    request_status.append_reasoning(status, "ses_1", "assistant_1", "part_1", " delta")
    request_status.append_reasoning(status, "ses_1", "assistant_1", "unknown", " wrong part")
    eq(rendered_lines(buf, status)[2][1][1], "  full delta")
    eq(rendered_lines(buf, status)[2][1][1]:find("wrong", 1, true), nil)
  end)
end

T["reasoning collapses whitespace and truncates by display width without splitting characters"] = function()
  with_status(function(status, _, buf)
    vim.api.nvim_win_set_width(0, 80)
    request_status.replace_reasoning(status, "ses_1", "assistant_1", "part_1", "  alpha\n\t beta  gamma ")
    eq(rendered_lines(buf, status)[2][1][1], "  alpha beta gamma")

    local source_win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 12,
      height = 3,
      style = "minimal",
    })
    local ok, failure = xpcall(function()
      eq(vim.api.nvim_get_current_win(), source_win)
      eq(vim.api.nvim_win_get_width(source_win), 12)
      request_status.replace_reasoning(status, "ses_1", "assistant_1", "part_2", "123456789中界")
      local line = rendered_lines(buf, status)[2][1][1]
      eq(line, "  123456789…")
      eq(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(source_win), true)
    end, debug.traceback)
    if vim.api.nvim_win_is_valid(source_win) then
      vim.api.nvim_win_close(source_win, true)
    end
    assert(ok, failure)
  end)
end

T["cleanup is idempotent and forgets the timer and extmark"] = function()
  with_status(function(status, _, buf, timer)
    local namespace = vim.api.nvim_get_namespaces()["opencode-build-request-status"]
    local extmark_id = status.extmark_id
    request_status.cleanup(status)
    request_status.cleanup(status)
    eq({ status.extmark_id, status.timer, timer.stopped, timer.closed }, { nil, nil, true, true })
    eq(#vim.api.nvim_buf_get_extmark_by_id(buf, namespace, extmark_id, {}), 0)
  end)
end

T["cleanup tolerates a source buffer deleted before the status"] = function()
  with_status(function(status, _, buf, timer)
    vim.api.nvim_buf_delete(buf, { force = true })
    request_status.cleanup(status)
    eq({ status.extmark_id, status.timer, timer.stopped, timer.closed }, { nil, nil, true, true })
  end)
end

return T
