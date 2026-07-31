local M = {}

M.namespace = vim.api.nvim_create_namespace("opencode-build-scope")

local function range_offsets(buf, text, range)
  if range.kind == "block" then
    return nil, nil, "blockwise_selection"
  end
  local start_byte, err = require("opencode.snapshot").position_to_offset(text, range.from[1] - 1, range.from[2])
  if not start_byte then
    return nil, nil, err
  end
  if range.kind == "bytes" then
    local end_byte, end_error = require("opencode.snapshot").position_to_offset(text, range.to[1] - 1, range.to[2])
    return start_byte, end_byte, end_error
  end
  if range.kind == "line" then
    local row = range.to[1] - 1
    local next_row = require("opencode.snapshot").position_to_offset(text, row + 1, 0)
    return start_byte, next_row or #text
  end
  local selected_line = vim.api.nvim_buf_get_lines(buf, range.to[1] - 1, range.to[1], false)[1] or ""
  local end_col = math.min(range.to[2] + 1, #selected_line)
  while end_col < #selected_line and selected_line:byte(end_col + 1) >= 128 and selected_line:byte(end_col + 1) < 192 do
    end_col = end_col + 1
  end
  local end_byte, end_error = require("opencode.snapshot").position_to_offset(text, range.to[1] - 1, end_col)
  return start_byte, end_byte, end_error
end

---Resolves an invocation range, nearest function, or full file into immutable Base byte offsets.
---An explicit file override can only widen a range or function and parser failures fail safely to file.
---@param context table
---@param base table
---@param override? "file"
---@return table?
---@return string?
function M.resolve(context, base, override)
  local kind, range = "file", nil
  if override ~= "file" and context.range then
    kind, range = "range", context.range
  elseif override ~= "file" then
    range = require("opencode.scope.treesitter").function_range(context.buf, context.cursor)
    kind = range and "function" or "file"
  end
  local start_byte, end_byte = 0, #base.text
  if range then
    local resolved_start, resolved_end, err = range_offsets(context.buf, base.text, range)
    if not resolved_start or not resolved_end then
      return nil, err
    end
    start_byte, end_byte = resolved_start, resolved_end
  end
  return { kind = kind, path = context.path, start_byte = start_byte, end_byte = end_byte }
end

---Creates the two gravity-aware marks that track a Build scope in current buffer text.
---@param buf integer
---@param scope table
---@return table
function M.create_marks(buf, scope)
  local snapshot = require("opencode.snapshot")
  local start_row, start_col = assert(
    snapshot.offset_to_position(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), scope.start_byte)
  )
  local end_row, end_col = assert(
    snapshot.offset_to_position(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), scope.end_byte)
  )
  return {
    start_id = vim.api.nvim_buf_set_extmark(buf, M.namespace, start_row, start_col, {
      right_gravity = false,
      end_row = end_row,
      end_col = end_col,
      end_right_gravity = true,
      hl_group = "OpencodeScope",
      hl_mode = "combine",
    }),
    end_id = vim.api.nvim_buf_set_extmark(buf, M.namespace, end_row, end_col, { right_gravity = true }),
  }
end

---Reads a Job's current half-open byte range from its extmark pair.
---Missing marks are reported separately from overlap because they indicate invalid Job state.
---@param job table
---@return table?
---@return string?
function M.current_range(job)
  if not vim.api.nvim_buf_is_valid(job.buffer) or not job.marks then
    return nil, "invalid_marks"
  end
  local start = vim.api.nvim_buf_get_extmark_by_id(job.buffer, M.namespace, job.marks.start_id, {})
  local finish = vim.api.nvim_buf_get_extmark_by_id(job.buffer, M.namespace, job.marks.end_id, {})
  if #start == 0 or #finish == 0 then
    return nil, "invalid_marks"
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(job.buffer, 0, -1, false), "\n")
  local start_byte = require("opencode.snapshot").position_to_offset(text, start[1], start[2])
  local end_byte = require("opencode.snapshot").position_to_offset(text, finish[1], finish[2])
  if not start_byte or not end_byte then
    return nil, "invalid_marks"
  end
  return { start_byte = start_byte, end_byte = end_byte }
end

function M.overlaps(a, b)
  if a.start_byte == a.end_byte and b.start_byte == b.end_byte then
    return a.start_byte == b.start_byte
  end
  return a.start_byte < b.end_byte and b.start_byte < a.end_byte
end

local function invalid_range(job, range)
  return range.start_byte > range.end_byte
    or (job.scope.start_byte < job.scope.end_byte and range.start_byte == range.end_byte)
end

---Snapshots and validates every active Build scope in one buffer.
---Missing, reversed, collapsed, and pairwise overlapping ranges fail as one scope violation.
---The snapshot lets callers validate before merge and again in the final mutation callback.
---@param runtime table
---@param buf integer
---@return table?
---@return string?
function M.active_ranges(runtime, buf)
  local ranges = {}
  for key, job in pairs(runtime.jobs) do
    if job.mode == "build" and job.buffer == buf and not require("opencode.job").terminal(job.state) then
      local range = M.current_range(job)
      if not range or invalid_range(job, range) then
        return nil, "scope_overlap"
      end
      for _, existing in ipairs(ranges) do
        if M.overlaps(range, existing.range) then
          return nil, "scope_overlap"
        end
      end
      table.insert(ranges, { key = key, range = range })
    end
  end
  return ranges
end

---Returns whether a pending mutation would enter another active Job's current scope.
---Touching ranges stay valid, while two insertions at the same empty-file position collide.
---@param runtime table
---@param job table
---@param span table
---@return boolean
function M.mutation_overlaps(runtime, job, span)
  local changed = { start_byte = span.start_byte, end_byte = span.ours_end }
  for key, other in pairs(runtime.jobs) do
    if
      key ~= job.key
      and other.mode == "build"
      and other.buffer == job.buffer
      and not require("opencode.job").terminal(other.state)
    then
      local range = M.current_range(other)
      if not range or M.overlaps(changed, range) then
        return true
      end
    end
  end
  return false
end

---Finds the first active Build Job whose current range overlaps a candidate.
---@param runtime table
---@param buf integer
---@param candidate table
---@param except_key? string
---@return table?
function M.find_overlap(runtime, buf, candidate, except_key)
  for key, job in pairs(runtime.jobs) do
    if
      key ~= except_key
      and job.mode == "build"
      and job.buffer == buf
      and not require("opencode.job").terminal(job.state)
    then
      local current = M.current_range(job)
      if not current or invalid_range(job, current) or M.overlaps(candidate, current) then
        return job
      end
    end
  end
  return nil
end

function M.delete_marks(job)
  if job.marks and vim.api.nvim_buf_is_valid(job.buffer) then
    pcall(vim.api.nvim_buf_del_extmark, job.buffer, M.namespace, job.marks.start_id)
    pcall(vim.api.nvim_buf_del_extmark, job.buffer, M.namespace, job.marks.end_id)
  end
  job.marks = nil
end

return M
