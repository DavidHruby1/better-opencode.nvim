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

---Captures the source facts required by every automatic or user-confirmed apply path.
---It rejects Insert mode, invalid ownership marks, overlapping scopes, and unsafe disk content before merge work begins.
local function source_state(job, runtime)
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    return nil, "insert_mode"
  end
  if
    not vim.api.nvim_buf_is_valid(job.buffer)
    or not vim.bo[job.buffer].modifiable
    or require("opencode.runtime.root").realpath(vim.api.nvim_buf_get_name(job.buffer)) ~= job.path
  then
    return nil, "invalid_buffer"
  end
  local range, range_error = require("opencode.scope").current_range(job)
  if not range then
    return nil, range_error
  end
  local active_ranges = require("opencode.scope").active_ranges(runtime, job.buffer)
  if not active_ranges then
    return nil, "scope_overlap"
  end
  local ours = logical(job.buffer)
  local _, disk_sha, disk_error = current_disk(job, ours)
  if disk_error then
    return nil, disk_error, disk_sha
  end
  return { ours = ours, tick = vim.api.nvim_buf_get_changedtick(job.buffer), disk_sha = disk_sha }
end

local function terminate(job, runtime, state, conflict_kind, conflict_payload)
  local session = runtime.sessions[job.session_id]
  if conflict_kind then
    local changed = require("opencode.job").transition(job, "conflict", {
      session = session,
      conflict_kind = conflict_kind,
      conflict_payload = conflict_payload,
    })
    if changed then
      require("opencode.interaction").enqueue({
        kind = conflict_kind == "agent" and "agent_conflict" or "external_change",
        root = job.root,
        session_id = job.session_id,
        session_short_id = job.session_id:sub(-8),
        job_key = job.key,
        payload = job.conflict_payload,
      })
      local notify = require("opencode.ui.notify")
      notify.emit("conflict", notify.snapshot(runtime, job), runtime)
    end
  else
    if state == "error" and not job.error_class then
      job.error_class = "apply_error"
    end
    require("opencode.job").transition(job, state, { session = session })
  end
end

---Applies a merge result only when both Job and Runtime generations still own the scheduled callback.
local function apply_result(
  job,
  runtime,
  generation,
  runtime_generation,
  ours,
  tick,
  disk_sha,
  result,
  expected_state,
  callback
)
  vim.schedule(function()
    expected_state = expected_state or "pending_apply"
    if
      job.state ~= expected_state
      or job.apply_generation ~= generation
      or runtime.generation ~= runtime_generation
    then
      if callback then
        callback(false, "stale_generation")
      end
      return
    end
    local current, state_error, current_sha = source_state(job, runtime)
    if not current then
      if expected_state == "pending_apply" then
        if state_error == "external_change" then
          terminate(job, runtime, nil, "external_change", { disk_sha = current_sha })
        elseif state_error == "insert_mode" then
          M.start(job, runtime)
        else
          terminate(job, runtime, state_error == "scope_overlap" and "scope_violation" or "error")
        end
      elseif callback then
        callback(false, state_error)
      end
      return
    end
    if current.tick ~= tick or current.disk_sha ~= disk_sha or current.ours ~= ours then
      if expected_state == "pending_apply" then
        M.start(job, runtime)
      elseif callback then
        callback(false, "stale_source")
      end
      return
    end
    if result:find("\0", 1, true) or result:find("\r", 1, true) then
      if expected_state == "pending_apply" then
        terminate(job, runtime, "error")
      elseif callback then
        callback(false, "invalid_result")
      else
        terminate(job, runtime, "error")
      end
      return
    end
    local span = M.changed_span(ours, result)
    local final_ranges = require("opencode.scope").active_ranges(runtime, job.buffer)
    if not final_ranges or require("opencode.scope").mutation_overlaps(runtime, job, span) then
      if expected_state == "pending_apply" then
        terminate(job, runtime, "scope_violation")
      elseif callback then
        callback(false, "scope_overlap")
      end
      return
    end
    local start_row, start_col = require("opencode.snapshot").offset_to_position(ours, span.start_byte)
    local end_row, end_col = require("opencode.snapshot").offset_to_position(ours, span.ours_end)
    if not start_row or not end_row then
      terminate(job, runtime, "error")
      return
    end
    local views = save_views(job.buffer)
    local applied = pcall(
      vim.api.nvim_buf_set_text,
      job.buffer,
      start_row,
      start_col,
      end_row,
      end_col,
      vim.split(span.replacement, "\n", { plain = true })
    )
    if not applied then
      terminate(job, runtime, "error")
      if callback then
        callback(false, "buffer_apply")
      end
      return
    end
    restore_views(job.buffer, views)
    terminate(job, runtime, "completed")
    if callback then
      callback(true)
    end
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
  local current, state_error, disk_sha = source_state(job, runtime)
  if not current then
    if state_error == "external_change" then
      terminate(job, runtime, nil, "external_change", { disk_sha = disk_sha })
    elseif state_error == "insert_mode" then
      if not job.insert_leave then
        job.insert_leave = vim.api.nvim_create_autocmd("InsertLeave", {
          buffer = job.buffer,
          once = true,
          callback = function()
            job.insert_leave = nil
            M.start(job, runtime)
          end,
        })
      end
    else
      terminate(job, runtime, state_error == "scope_overlap" and "scope_violation" or "error")
    end
    return
  end
  local ours, tick = current.ours, current.tick
  disk_sha = current.disk_sha
  job.apply_generation = (job.apply_generation or 0) + 1
  local generation = job.apply_generation
  local runtime_generation = runtime.generation
  require("opencode.merge")
    .run(job.base.text, ours, job.theirs, {
      owner_key = job.merge_key or job.key,
      temp_dir = runtime.temp_root,
    })
    :next(function(merge)
      if merge.kind == "conflict" then
        if job.state == "pending_apply" and job.apply_generation == generation then
          terminate(job, runtime, nil, "agent", { base = job.base, ours = ours, theirs = job.theirs })
        end
        return
      end
      apply_result(job, runtime, generation, runtime_generation, ours, tick, disk_sha, merge.text)
    end)
    :catch(function()
      if job.state == "pending_apply" and job.apply_generation == generation then
        terminate(job, runtime, "error")
      end
    end)
end

---Resolves every agent conflict hunk with one merge-file preference and applies through the normal stale-checked path.
---Fresh Ours and disk state are captured before the process; clean hunks from both sides remain in its output.
function M.prefer(job, runtime, preference, callback)
  if job.state ~= "conflict" or job.conflict_kind ~= "agent" or (preference ~= "ours" and preference ~= "theirs") then
    return false
  end
  local payload = job.conflict_payload
  local current, state_error = source_state(job, runtime)
  if not current then
    if callback then
      callback(false, state_error)
    end
    return false
  end
  job.apply_generation = (job.apply_generation or 0) + 1
  local generation = job.apply_generation
  local runtime_generation = runtime.generation
  require("opencode.merge")
    .run(payload.base.text, current.ours, payload.theirs, {
      preference = preference,
      owner_key = job.merge_key or job.key,
      temp_dir = runtime.temp_root,
    })
    :next(function(result)
      if result.kind ~= "clean" or job.state ~= "conflict" then
        require("opencode.job").transition(job, "error", { session = runtime.sessions[job.session_id] })
        return
      end
      apply_result(
        job,
        runtime,
        generation,
        runtime_generation,
        current.ours,
        current.tick,
        current.disk_sha,
        result.text,
        "conflict",
        callback
      )
    end)
    :catch(function()
      require("opencode.job").transition(job, "error", { session = runtime.sessions[job.session_id] })
    end)
  return true
end

---Applies an explicitly confirmed manual result only after fresh source and disk checks.
---The same minimal-span mutation path is used so confirmation remains one undoable buffer edit.
function M.manual(job, runtime, result, callback)
  if
    job.state ~= "conflict"
    or job.conflict_kind ~= "agent"
    or result:find("\0", 1, true)
    or result:find("\r", 1, true)
  then
    if callback then
      callback(false, "invalid_result")
    end
    return false
  end
  local current, state_error = source_state(job, runtime)
  if not current then
    if callback then
      callback(false, state_error)
    end
    return false
  end
  job.apply_generation = (job.apply_generation or 0) + 1
  apply_result(
    job,
    runtime,
    job.apply_generation,
    runtime.generation,
    current.ours,
    current.tick,
    current.disk_sha,
    result,
    "conflict",
    callback
  )
  return true
end

---Retries an external conflict only when fresh disk logical text exactly equals fresh Ours.
---The old merge result is discarded and the standard apply pipeline recomputes from Base/Ours/Theirs.
function M.retry(job, runtime, callback)
  if job.state ~= "conflict" or job.conflict_kind ~= "external_change" then
    return false
  end
  local current, state_error = source_state(job, runtime)
  if not current then
    if callback then
      callback(false, state_error)
    end
    return false
  end
  local ours = current.ours
  local raw = require("opencode.snapshot").read_raw(job.path)
  local disk = raw and require("opencode.snapshot").decode_disk(raw, job.base)
  if disk ~= ours then
    require("opencode.ui.notify").warn("save_or_reconcile")
    return false
  end
  job.apply_generation = (job.apply_generation or 0) + 1
  local generation = job.apply_generation
  local runtime_generation = runtime.generation
  require("opencode.merge")
    .run(job.base.text, ours, job.theirs, {
      owner_key = job.merge_key or job.key,
      temp_dir = runtime.temp_root,
    })
    :next(function(result)
      if job.state ~= "conflict" or job.apply_generation ~= generation then
        return
      end
      if result.kind == "conflict" then
        job.conflict_kind = "agent"
        job.conflict_payload = vim.deepcopy({ base = job.base, ours = ours, theirs = job.theirs })
        require("opencode.interaction").replace_current_conflict(
          job.root,
          job.key,
          "agent_conflict",
          job.conflict_payload
        )
        if callback then
          callback(false, "agent_conflict")
        end
        return
      end
      apply_result(
        job,
        runtime,
        generation,
        runtime_generation,
        ours,
        current.tick,
        current.disk_sha,
        result.text,
        "conflict",
        callback
      )
    end)
    :catch(function()
      require("opencode.job").transition(job, "error", { session = runtime.sessions[job.session_id] })
    end)
  return true
end

return M
