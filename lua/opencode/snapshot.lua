local M = {}

local function raw_file(path)
  local handle, open_error = vim.uv.fs_open(path, "r", 438)
  if not handle then
    return nil, open_error
  end
  local stat, stat_error = vim.uv.fs_fstat(handle)
  if not stat then
    vim.uv.fs_close(handle)
    return nil, stat_error
  end
  local bytes, read_error = vim.uv.fs_read(handle, stat.size, 0)
  vim.uv.fs_close(handle)
  return bytes, read_error
end

local function valid_utf8(text)
  return pcall(vim.str_utfindex, text)
end

---Returns the exact bytes and SHA-256 currently stored at a path.
---Binary reads avoid newline normalization so disk races can be detected reliably.
---@param path string
---@return string?
---@return string?
function M.read_raw(path)
  local bytes, err = raw_file(path)
  if not bytes then
    return nil, err
  end
  return bytes, vim.fn.sha256(bytes)
end

---Turns raw file bytes into the logical text represented by a captured buffer.
---It validates the captured EOL convention and removes only the synthetic final line ending.
---@param raw string
---@param metadata table
---@return string?
---@return string?
function M.decode_disk(raw, metadata)
  if raw:find("\0", 1, true) or not valid_utf8(raw) then
    return nil, "unsupported_encoding"
  end
  local text = raw
  if metadata.fileformat == "dos" then
    if text:gsub("\r\n", ""):find("\r", 1, true) or text:gsub("\r\n", ""):find("\n", 1, true) then
      return nil, "mixed_eol"
    end
    text = text:gsub("\r\n", "\n")
  elseif text:find("\r", 1, true) then
    return nil, "mixed_eol"
  end
  if metadata.endofline and text:sub(-1) == "\n" then
    text = text:sub(1, -2)
  end
  return text
end

---Captures immutable logical buffer text, options, changedtick, and the raw disk fingerprint.
---Logical text is independent of file EOL bytes so merge and buffer APIs use one representation.
---@param buf integer
---@return table?
---@return string?
function M.capture(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil, "invalid_buffer"
  end
  local path = vim.api.nvim_buf_get_name(buf)
  local raw, disk_sha256 = M.read_raw(path)
  if not raw then
    return nil, "disk_read"
  end
  return {
    text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
    sha256 = vim.fn.sha256(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")),
    changedtick = vim.api.nvim_buf_get_changedtick(buf),
    fileformat = vim.bo[buf].fileformat,
    endofline = vim.bo[buf].endofline,
    fixendofline = vim.bo[buf].fixendofline,
    disk_sha256 = disk_sha256,
  }
end

---Converts a valid UTF-8 byte boundary to zero-based Neovim row and byte column.
---Rejecting mid-codepoint offsets prevents a later set_text call from splitting source text.
---@param text string
---@param offset integer
---@return integer?
---@return integer|string
function M.offset_to_position(text, offset)
  if offset < 0 or offset > #text then
    return nil, "offset_out_of_range"
  end
  if offset < #text and text:byte(offset + 1) >= 128 and text:byte(offset + 1) < 192 then
    return nil, "mid_codepoint"
  end
  local prefix = text:sub(1, offset)
  local last_newline = prefix:match(".*()\n")
  local row = select(2, prefix:gsub("\n", ""))
  return row, last_newline and offset - last_newline or offset
end

---Converts a zero-based row and byte column to an absolute UTF-8 byte boundary.
---The line table is derived from logical text, including a real trailing empty logical line.
---@param text string
---@param row integer
---@param col integer
---@return integer?
---@return string?
function M.position_to_offset(text, row, col)
  if row < 0 or col < 0 then
    return nil, "position_out_of_range"
  end
  local offset, current = 0, 0
  while current < row do
    local newline = text:find("\n", offset + 1, true)
    if not newline then
      return nil, "position_out_of_range"
    end
    offset, current = newline, current + 1
  end
  local line_end = text:find("\n", offset + 1, true)
  local length = (line_end and line_end - 1 or #text) - offset
  if col > length then
    return nil, "position_out_of_range"
  end
  local absolute = offset + col
  if absolute < #text and text:byte(absolute + 1) >= 128 and text:byte(absolute + 1) < 192 then
    return nil, "mid_codepoint"
  end
  return absolute
end

return M
