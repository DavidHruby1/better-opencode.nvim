local M = {}

local function logical(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function disk_logical(buf)
  local raw = assert(require("opencode.snapshot").read_raw(vim.api.nvim_buf_get_name(buf)))
  return require("opencode.snapshot").decode_disk(raw, {
    fileformat = vim.bo[buf].fileformat,
    endofline = vim.bo[buf].endofline,
  })
end

---Saves dirty files before dispatch, asking for confirmation only for Plan.
---Build writes immediately; Plan offers save and cancel. Every write is checked after hooks, and failure stops dispatch before Session or Job creation.
---@param context table
---@param mode? "plan"|"build"
---@return Promise<boolean>
function M.run(context, mode)
  local Promise = require("opencode.promise")
  local dirty = {}
  context.referenced_buffers[context.buf] = true
  for buf in pairs(context.referenced_buffers) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
      table.insert(dirty, buf)
    end
  end
  table.sort(dirty, function(a, b)
    return vim.api.nvim_buf_get_name(a) < vim.api.nvim_buf_get_name(b)
  end)
  if #dirty == 0 then
    return Promise.resolve(true)
  end
  local function save()
    for _, buf in ipairs(dirty) do
      local ok = pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd.write()
      end)
      if not ok or vim.bo[buf].modified or logical(buf) ~= disk_logical(buf) then
        return Promise.reject({ error_class = "write_failed" })
      end
    end
    return Promise.resolve(true)
  end
  if mode == "build" then
    return save()
  end
  return require("opencode.promise.ui")
    .select({ "save and continue", "cancel" }, {
      prompt = "Dirty files: " .. #dirty,
    })
    :next(function(choice)
      if choice ~= "save and continue" then
        return Promise.reject({ error_class = "cancelled" })
      end
      return save()
    end)
end

return M
