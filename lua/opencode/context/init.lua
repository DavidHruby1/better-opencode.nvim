local Context = {}
Context.__index = Context

---Reads the exact file bytes and maps filesystem failures to the public context error class.
---The shared snapshot reader closes opened handles and keeps system error details out of notifications.
local function raw_file(path)
  local bytes = require("opencode.snapshot").read_raw(path)
  if not bytes then
    return nil, "disk_read"
  end
  return bytes, nil
end

---@class opencode.context.Range
---@field from integer[]
---@field to integer[]
---@field kind "char"|"line"|"block"

local function visual_range(buf)
  local mode = vim.fn.mode()
  local kind = mode == "v" and "char" or mode == "V" and "line" or mode == "\22" and "block" or nil
  if not kind then
    return nil
  end
  local from = vim.api.nvim_buf_get_mark(buf, "<")
  local to = vim.api.nvim_buf_get_mark(buf, ">")
  if from[1] > to[1] or (from[1] == to[1] and from[2] > to[2]) then
    from, to = to, from
  end
  return { from = { from[1], from[2] }, to = { to[1], to[2] }, kind = kind }
end

---Captures immutable editor identity before any prompt UI changes focus.
---Unsupported targets keep their specific class. File read failures return a safe disk_read error through the public flow.
---@param range? opencode.context.Range
---@return table?
---@return string?
function Context.capture(range)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return nil, "unnamed_buffer"
  end
  if not vim.bo[buf].buflisted or vim.bo[buf].buftype ~= "" then
    return nil, "unsupported_buffer"
  end
  local real = require("opencode.runtime.root").realpath(path)
  local stat = real and vim.uv.fs_stat(real)
  if not stat or stat.type ~= "file" then
    return nil, "not_regular_file"
  end
  local bytes, read_error = raw_file(real)
  if not bytes then
    return nil, read_error
  end
  if bytes:find("\0", 1, true) then
    return nil, "nul_file"
  end
  if not require("opencode.snapshot").valid_utf8(bytes) then
    return nil, "non_utf8_file"
  end
  return {
    win = win,
    buf = buf,
    path = real,
    cursor = vim.api.nvim_win_get_cursor(win),
    range = range or visual_range(buf),
  }
end

---Creates context bound to one ready Runtime and immutable editor capture.
---@param capture table
---@param runtime table
---@return table
function Context.new(capture, runtime)
  return setmetatable({
    win = capture.win,
    buf = capture.buf,
    path = capture.path,
    cursor = vim.deepcopy(capture.cursor),
    range = vim.deepcopy(capture.range),
    root = runtime.root,
    runtime = runtime,
    referenced_buffers = {},
  }, Context)
end

---Formats only canonical file-backed locations, optionally with one line/column range.
---@param opts { path?: string, buf?: integer, from?: integer[], to?: integer[], rel?: string }
---@return string?
function Context.format(opts)
  local path = opts.path or (opts.buf and vim.api.nvim_buf_get_name(opts.buf))
  local real = path and require("opencode.runtime.root").realpath(path)
  local stat = real and vim.uv.fs_stat(real)
  if not stat or stat.type ~= "file" then
    return nil
  end
  ---@cast real string
  local result = real
  local rel = opts.rel and require("opencode.runtime.root").realpath(opts.rel)
  if rel and require("opencode.runtime.root").contains(rel, real) then
    result = real:sub(#rel + 2)
  end
  if opts.from then
    result = result .. string.format(":L%d", opts.from[1])
    if opts.from[2] then
      result = result .. string.format(":C%d", opts.from[2])
    end
    if opts.to then
      result = result .. string.format("-L%d", opts.to[1])
      if opts.to[2] then
        result = result .. string.format(":C%d", opts.to[2])
      end
    end
  end
  return result
end

---Returns configured context placeholders longest-first for matching and expansion.
---Sorting longer keys first keeps overlapping placeholders such as `@buffers` ahead of `@buffer`.
local function context_keys()
  local keys = vim.tbl_keys(require("opencode.config").opts.contexts)
  table.sort(keys, function(a, b)
    return #a > #b
  end)
  return keys
end

---Splits prompt text into plain and highlighted context-placeholder segments.
---The earliest match wins and longer keys win ties, so `@buffers` is never partially styled as `@buffer`.
local function input_segments(prompt, keys)
  local segments = {}
  local cursor = 1
  while cursor <= #prompt do
    local match_start, match_end, match_key
    for _, key in ipairs(keys) do
      local start_at, end_at = prompt:find(key, cursor, true)
      if start_at and (not match_start or start_at < match_start or start_at == match_start and #key > #match_key) then
        match_start, match_end, match_key = start_at, end_at, key
      end
    end
    if not match_start then
      table.insert(segments, { prompt:sub(cursor) })
      break
    end
    if match_start > cursor then
      table.insert(segments, { prompt:sub(cursor, match_start - 1) })
    end
    table.insert(segments, { match_key, "OpencodeContextPlaceholder" })
    cursor = match_end + 1
  end
  if #segments == 0 then
    table.insert(segments, { prompt })
  end
  return segments
end

---Identifies configured placeholders without calling their providers or changing referenced buffers.
---The returned segments are used only for prompt highlighting; full expansion stays in `render` for submit and completion resolution.
---@param prompt string
---@return opencode.context.rendered.Rendered
function Context:input(prompt)
  local Rendered = require("opencode.context.rendered")
  return setmetatable(input_segments(prompt, context_keys()), Rendered)
end

---Expands configured placeholders and prepends the active location exactly once.
---Input keeps cheap placeholder segments for multiline highlights while output calls providers and records referenced buffers for dirty preflight.
---@param prompt string
---@return { input: table, output: table, plaintext: string }
function Context:render(prompt)
  local contexts = require("opencode.config").opts.contexts
  local keys = context_keys()
  local output = prompt
  for _, key in ipairs(keys) do
    if output:find(key, 1, true) then
      local value = contexts[key](self) or key
      output = output:gsub(vim.pesc(key), function()
        return value
      end)
    end
  end
  local location = require("opencode.context.builtins").this(self)
  if not output:find(location, 1, true) then
    output = location .. "\n\n" .. output
  end
  local Rendered = require("opencode.context.rendered")
  return {
    input = self:input(prompt),
    output = setmetatable({ { output } }, Rendered),
    plaintext = output,
  }
end

return Context
