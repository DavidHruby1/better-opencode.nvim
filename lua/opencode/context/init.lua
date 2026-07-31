local Context = {}
Context.__index = Context

local function raw_file(path)
  local handle = assert(vim.uv.fs_open(path, "r", 438))
  local stat = assert(vim.uv.fs_fstat(handle))
  local bytes = assert(vim.uv.fs_read(handle, stat.size, 0))
  vim.uv.fs_close(handle)
  return bytes
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
  local bytes = raw_file(real)
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

---Expands configured placeholders and prepends the active location exactly once.
---Referenced file buffers are recorded for the shared dirty-buffer preflight.
---@param prompt string
---@return { input: table, output: table, plaintext: string }
function Context:render(prompt)
  local contexts = require("opencode.config").opts.contexts
  local keys = vim.tbl_keys(contexts)
  table.sort(keys, function(a, b)
    return #a > #b
  end)
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
    input = setmetatable({ { prompt } }, Rendered),
    output = setmetatable({ { output } }, Rendered),
    plaintext = output,
  }
end

return Context
