local M = {}

local function logical(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function disk_logical(buf)
  local raw = require("opencode.snapshot").read_raw(vim.api.nvim_buf_get_name(buf))
  if not raw then
    return nil
  end
  return require("opencode.snapshot").decode_disk(raw, {
    fileformat = vim.bo[buf].fileformat,
    endofline = vim.bo[buf].endofline,
  })
end

local function referenced(context)
  local buffers = vim.deepcopy(context.referenced_buffers)
  buffers[context.buf] = true
  return buffers
end

local function dirty_buffers(context)
  local dirty = {}
  for buf in pairs(referenced(context)) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
      table.insert(dirty, buf)
    end
  end
  table.sort(dirty, function(a, b)
    return vim.api.nvim_buf_get_name(a) < vim.api.nvim_buf_get_name(b)
  end)
  return dirty
end

---Saves the current target and referenced files after their providers have run.
---Temporary scope marks follow BufWritePre edits in the target; failed writes, stale paths, invalid UTF-8, or lost marks
---stop dispatch before Base capture. The caller rerenders after a write because hooks may change provider results.
---@param context table
---@return boolean?
---@return string?
---@return boolean?
function M.save(context)
  local dirty = dirty_buffers(context)
  if #dirty == 0 then
    return true, nil, false
  end

  local tracker, track_error = require("opencode.scope").track_context(context)
  if not tracker then
    return nil, track_error
  end
  for _, buf in ipairs(dirty) do
    local text = logical(buf)
    local path = vim.api.nvim_buf_get_name(buf)
    local real = path ~= "" and require("opencode.runtime.root").realpath(path)
    local stat = real and vim.uv.fs_stat(real)
    if
      not stat
      or stat.type ~= "file"
      or text:find("\0", 1, true)
      or not require("opencode.snapshot").valid_utf8(text)
    then
      require("opencode.scope").discard_context_tracker(context, tracker)
      return nil, "write_failed"
    end
    local ok = pcall(vim.api.nvim_buf_call, buf, function()
      vim.cmd.write()
    end)
    local final_path = require("opencode.runtime.root").realpath(vim.api.nvim_buf_get_name(buf))
    if not ok or final_path ~= real or vim.bo[buf].modified or logical(buf) ~= disk_logical(buf) then
      require("opencode.scope").discard_context_tracker(context, tracker)
      return nil, "write_failed"
    end
    if buf == context.buf and final_path ~= context.path then
      require("opencode.scope").discard_context_tracker(context, tracker)
      return nil, "write_failed"
    end
  end
  local restored, restore_error = require("opencode.scope").restore_context(context, tracker)
  if not restored then
    return nil, restore_error
  end
  return true, nil, true
end

---Runs one save pass for callers that already know every referenced buffer.
---Prompt dispatch performs provider expansion in Context.render before calling this repeatedly, so this compatibility entrypoint
---does not save early and cannot miss references discovered by the prompt.
---@param context table
---@return Promise<boolean>
function M.run(context)
  return require("opencode.promise").resolve(true)
end

---Normalizes the target before a prompt displays its scope.
---No prompt providers exist at this point, so only the target and references explicitly attached by the caller are saved.
---@param context table
---@return boolean?
---@return string?
function M.prepare_scope(context)
  local references = context.referenced_buffers
  context.referenced_buffers = {}
  for buf in pairs(references) do
    if not context.provider_referenced_buffers[buf] then
      context.referenced_buffers[buf] = true
    end
  end
  local ok, err = M.save(context)
  context.referenced_buffers = references
  return ok, err
end

return M
