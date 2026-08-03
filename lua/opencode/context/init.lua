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

---Returns the active Visual selection as ordered, zero-based buffer positions.
---The live endpoints are used because the '< and '> marks still describe the previous selection until Visual mode ends.
local function visual_range()
  local mode = vim.fn.mode()
  local kind = mode == "v" and "char" or mode == "V" and "line" or mode == "\22" and "block" or nil
  if not kind then
    return nil
  end

  local positions = vim.fn.getregionpos(vim.fn.getpos("v"), vim.fn.getpos("."), {
    type = mode,
    exclusive = false,
    eol = false,
  })
  if #positions == 0 then
    return nil
  end

  local first = positions[1][1]
  local last = positions[#positions][2]
  local from = { first[2], math.max(first[3] - 1, 0) }
  local to = { last[2], math.max(last[3] - 1, 0) }
  if kind == "line" then
    from[2], to[2] = 0, 0
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
    range = range or visual_range(),
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
    provider_referenced_buffers = {},
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

---Expands configured placeholders once and records only references from that result.
---References attached before rendering remain explicit inputs, while stale provider references from an earlier pass are removed.
---@param prompt string
---@param explicit table<integer, boolean>
---@return string
function Context:_expand(prompt, explicit)
  self.referenced_buffers = vim.deepcopy(explicit)
  local contexts = require("opencode.config").opts.contexts
  local output = prompt
  for _, key in ipairs(context_keys()) do
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
  return output
end

---Expands placeholder documentation without saving files or retaining provider references.
---The original references are restored before expansion errors are rethrown.
---Completion previews may call providers for useful text, but they must not turn browsing a completion menu into a write.
---@param prompt string
---@return { input: table, output: table, plaintext: string }
function Context:preview(prompt)
  local references = self.referenced_buffers
  local ok, output = pcall(self._expand, self, prompt, references)
  self.referenced_buffers = references
  if not ok then
    error(output, 0)
  end
  local Rendered = require("opencode.context.rendered")
  return {
    input = self:input(prompt),
    output = setmetatable({ { output } }, Rendered),
    plaintext = output,
  }
end

---Expands placeholders against the final post-save editor state and prepends the active location exactly once.
---Providers run before each save pass. After write hooks, expansion repeats until no referenced buffer is dirty and both the
---rendered text and reference set are stable; failure to settle rejects dispatch instead of capturing a stale Base.
---Input keeps cheap placeholder segments for multiline highlights without running providers.
---@param prompt string
---@return { input: table, output: table, plaintext: string }
function Context:render(prompt)
  local explicit = {}
  for buf in pairs(self.referenced_buffers) do
    if not self.provider_referenced_buffers[buf] then
      explicit[buf] = true
    end
  end
  local output
  local settled = false
  for _ = 1, 8 do
    output = self:_expand(prompt, explicit)
    local ok, err, wrote = require("opencode.context.preflight").save(self)
    if not ok then
      error({ error_class = err })
    end
    if not wrote then
      settled = true
      break
    end
  end
  if not settled then
    error({ error_class = "write_failed" })
  end
  output = assert(output)
  self.provider_referenced_buffers = {}
  for buf in pairs(self.referenced_buffers) do
    if not explicit[buf] then
      self.provider_referenced_buffers[buf] = true
    end
  end
  local Rendered = require("opencode.context.rendered")
  return {
    input = self:input(prompt),
    output = setmetatable({ { output } }, Rendered),
    plaintext = output,
  }
end

return Context
