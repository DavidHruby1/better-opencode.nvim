local M = {}

local function logical(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function boundary_before(text, offset)
  while offset > 0 and offset < #text and text:byte(offset + 1) >= 128 and text:byte(offset + 1) < 192 do
    offset = offset - 1
  end
  return offset
end

local function boundary_after(text, offset)
  while offset < #text and text:byte(offset + 1) >= 128 and text:byte(offset + 1) < 192 do
    offset = offset + 1
  end
  return offset
end

---Computes one minimal UTF-8-safe replacement between two logical texts.
---Byte-equal prefix and suffix are retained so unrelated extmarks move as little as possible.
---@param ours string
---@param result string
---@return table
function M.changed_span(ours, result)
  local prefix = 0
  while prefix < #ours and prefix < #result and ours:byte(prefix + 1) == result:byte(prefix + 1) do
    prefix = prefix + 1
  end
  prefix = math.min(boundary_before(ours, prefix), boundary_before(result, prefix))
  local ours_suffix, result_suffix = #ours, #result
  while ours_suffix > prefix and result_suffix > prefix and ours:byte(ours_suffix) == result:byte(result_suffix) do
    ours_suffix, result_suffix = ours_suffix - 1, result_suffix - 1
  end
  ours_suffix = boundary_after(ours, ours_suffix)
  result_suffix = boundary_after(result, result_suffix)
  return { start_byte = prefix, ours_end = ours_suffix, replacement = result:sub(prefix + 1, result_suffix) }
end

local function current_disk(job, ours)
  local raw, sha = require("opencode.snapshot").read_raw(job.path)
  if not raw then
    return nil, nil, "disk_read"
  end
  local disk, err = require("opencode.snapshot").decode_disk(raw, job.base)
  if not disk then
    return nil, nil, err
  end
  if disk ~= job.base.text and disk ~= ours then
    return nil, sha, "external_change"
  end
  return disk, sha
end

local function save_views(buf)
  local views = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    end
  end
  return views
end

local function restore_views(buf, views)
  local line_count = vim.api.nvim_buf_line_count(buf)
  for win, view in pairs(views) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(view)
      end)
      local cursor = vim.api.nvim_win_get_cursor(win)
      local row = math.max(1, math.min(cursor[1], line_count))
      local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
      vim.api.nvim_win_set_cursor(win, { row, math.min(cursor[2], #line) })
    end
  end
end

local function terminate(job, runtime, state, conflict_kind)
  local session = runtime.sessions[job.session_id]
  if conflict_kind then
    require("opencode.job").transition(job, session, "conflict", conflict_kind)
  else
    require("opencode.job").transition(job, session, state)
  end
end

local function apply_result(job, runtime, generation, ours, tick, disk_sha, result)
  vim.schedule(function()
    if job.state ~= "pending_apply" or job.apply_generation ~= generation then
      return
    end
    if
      not vim.api.nvim_buf_is_valid(job.buffer)
      or require("opencode.runtime.root").realpath(vim.api.nvim_buf_get_name(job.buffer)) ~= job.path
    then
      terminate(job, runtime, "error")
      return
    end
    local _, current_sha, disk_error = current_disk(job, logical(job.buffer))
    if disk_error then
      if disk_error == "external_change" then
        terminate(job, runtime, nil, "external_change")
      else
        terminate(job, runtime, "error")
      end
      return
    end
    if vim.api.nvim_buf_get_changedtick(job.buffer) ~= tick or current_sha ~= disk_sha then
      M.start(job, runtime)
      return
    end
    local span = M.changed_span(ours, result)
    local start_row, start_col = require("opencode.snapshot").offset_to_position(ours, span.start_byte)
    local end_row, end_col = require("opencode.snapshot").offset_to_position(ours, span.ours_end)
    if not start_row or not end_row then
      terminate(job, runtime, "error")
      return
    end
    local views = save_views(job.buffer)
    vim.api.nvim_buf_set_text(
      job.buffer,
      start_row,
      start_col,
      end_row,
      end_col,
      vim.split(span.replacement, "\n", { plain = true })
    )
    restore_views(job.buffer, views)
    terminate(job, runtime, "completed")
  end)
end

---Captures fresh Ours and disk state, validates active scopes, and starts one merge generation.
---A stale completion recursively starts only one replacement generation from current editor state.
---@param job table
---@param runtime table
function M.start(job, runtime)
  if job.state ~= "pending_apply" then
    return
  end
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    if job.insert_leave then
      return
    end
    job.insert_leave = vim.api.nvim_create_autocmd("InsertLeave", {
      buffer = job.buffer,
      once = true,
      callback = function()
        job.insert_leave = nil
        M.start(job, runtime)
      end,
    })
    return
  end
  local range, range_error = require("opencode.scope").current_range(job)
  if not range then
    terminate(job, runtime, range_error == "invalid_marks" and "error" or "scope_violation")
    return
  end
  local collapsed = job.scope.start_byte < job.scope.end_byte and range.start_byte == range.end_byte
  if
    range.start_byte > range.end_byte
    or collapsed
    or require("opencode.scope").find_overlap(runtime, job.buffer, range, job.key)
  then
    terminate(job, runtime, "scope_violation")
    return
  end
  local ours = logical(job.buffer)
  local _, disk_sha, disk_error = current_disk(job, ours)
  if disk_error then
    if disk_error == "external_change" then
      terminate(job, runtime, nil, "external_change")
    else
      terminate(job, runtime, "error")
    end
    return
  end
  local tick = vim.api.nvim_buf_get_changedtick(job.buffer)
  job.apply_generation = (job.apply_generation or 0) + 1
  local generation = job.apply_generation
  require("opencode.merge")
    .run(job.base.text, ours, job.theirs)
    :next(function(merge)
      if merge.kind == "conflict" then
        if job.state == "pending_apply" and job.apply_generation == generation then
          job.conflict_payload = vim.deepcopy({ base = job.base, ours = ours, theirs = job.theirs })
          terminate(job, runtime, nil, "agent")
        end
        return
      end
      apply_result(job, runtime, generation, ours, tick, disk_sha, merge.text)
    end)
    :catch(function()
      if job.state == "pending_apply" and job.apply_generation == generation then
        terminate(job, runtime, "error")
      end
    end)
end

return M
