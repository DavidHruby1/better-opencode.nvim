local M = {}

local namespace = vim.api.nvim_create_namespace("opencode-build-request-status")
local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---Chooses the source window whose width limits transient Build text.
---The current window wins when it shows the Job buffer; otherwise an existing window showing that buffer is used.
---No window is opened because the status must stay attached to the caller's editing context.
local function source_window(buf)
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(current) and vim.api.nvim_win_get_buf(current) == buf then
    return current
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
end

---Fits one display line within the current source window without splitting a character.
---An ellipsis replaces the omitted tail so long model reasoning cannot spill into adjacent editor space.
local function truncate_display(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local ellipsis = "…"
  local available = width - vim.fn.strdisplaywidth(ellipsis)
  if available < 1 then
    return ellipsis
  end
  local low, high = 0, vim.fn.strchars(text)
  while low < high do
    local middle = math.ceil((low + high) / 2)
    if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, middle)) <= available then
      low = middle
    else
      high = middle - 1
    end
  end
  return vim.fn.strcharpart(text, 0, low) .. ellipsis
end

---Renders the next spinner frame and the latest real reasoning at the moving scope anchor.
---Whitespace is collapsed and the source window is selected again on every render so edits and resizes stay accurate.
local function render(status)
  if status.cleaned or not vim.api.nvim_buf_is_valid(status.buffer) then
    return
  end
  local win = source_window(status.buffer)
  if not win then
    return
  end
  local position = vim.api.nvim_buf_get_extmark_by_id(status.buffer, namespace, status.extmark_id, {})
  if #position == 0 then
    return
  end
  status.frame = status.frame % #spinner + 1
  local lines = { { { spinner[status.frame] .. " Implementing", "Comment" } } }
  local reasoning = status.current_key and status.reasoning_parts[status.current_key]
  reasoning = type(reasoning) == "string" and reasoning:gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
  if reasoning ~= "" then
    table.insert(lines, { { truncate_display("  " .. reasoning, vim.api.nvim_win_get_width(win)), "Comment" } })
  end
  vim.api.nvim_buf_set_extmark(status.buffer, namespace, position[1], position[2], {
    id = status.extmark_id,
    right_gravity = false,
    virt_lines = lines,
  })
end

---Creates the transient inline display for one captured Build Job with valid scope marks.
---Its own extmark follows the scope start, while a libuv timer redraws the spinner without storing text on the Job.
---@param job table
---@return table
function M.new(job)
  local scope = require("opencode.scope")
  local position = vim.api.nvim_buf_get_extmark_by_id(job.buffer, scope.namespace, job.marks.start_id, {})
  assert(#position > 0, "Build request status requires a valid scope start")
  local status = {
    buffer = job.buffer,
    frame = 0,
    reasoning_parts = {},
  }
  status.extmark_id = vim.api.nvim_buf_set_extmark(job.buffer, namespace, position[1], position[2], {
    right_gravity = false,
  })
  status.timer = assert(vim.uv.new_timer())
  render(status)
  status.timer:start(
    80,
    80,
    vim.schedule_wrap(function()
      pcall(render, status)
    end)
  )
  return status
end

---Registers or replaces one exact reasoning part and makes its full text visible.
---The composite identity prevents later fragments from another Session, assistant, or part being borrowed.
function M.replace_reasoning(status, session_id, assistant_id, part_id, text)
  if status.cleaned then
    return
  end
  local key = table.concat({ session_id, assistant_id, part_id }, ":")
  status.reasoning_parts[key] = type(text) == "string" and text or ""
  status.current_key = key
  render(status)
end

---Appends a text fragment only to the exact reasoning part previously registered by a full update.
---Unknown and delta-first identities are discarded so stream timing cannot reassign model reasoning.
function M.append_reasoning(status, session_id, assistant_id, part_id, delta)
  if status.cleaned or type(delta) ~= "string" then
    return
  end
  local key = table.concat({ session_id, assistant_id, part_id }, ":")
  if status.reasoning_parts[key] == nil then
    return
  end
  status.reasoning_parts[key] = status.reasoning_parts[key] .. delta
  status.current_key = key
  render(status)
end

---Stops and removes one transient Build display and forgets all reasoning identities.
---Repeated calls and invalid buffers are safe because terminal and conflict paths can converge during cleanup.
function M.cleanup(status)
  if not status or status.cleaned then
    return
  end
  status.cleaned = true
  if status.timer then
    status.timer:stop()
    if not status.timer:is_closing() then
      status.timer:close()
    end
    status.timer = nil
  end
  if vim.api.nvim_buf_is_valid(status.buffer) and status.extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, status.buffer, namespace, status.extmark_id)
  end
  status.extmark_id = nil
  status.current_key = nil
  status.reasoning_parts = {}
end

return M
