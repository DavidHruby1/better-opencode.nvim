local M = {}

local function logical(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function disk_logical(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  local raw = table.concat(vim.fn.readfile(path, "b"), "\n")
  if vim.bo[buf].fileformat == "dos" then
    raw = raw:gsub("\r\n", "\n")
  end
  if vim.bo[buf].endofline and raw:sub(-1) == "\n" then
    raw = raw:sub(1, -2)
  end
  return raw
end

---Prompts once for the snapshotted dirty file set, then writes it in deterministic order.
---Every write is checked after hooks; failure stops dispatch before Session or Job creation.
---@param context table
---@return Promise<boolean>
function M.run(context)
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
  return require("opencode.promise.ui")
    .select({ "save and continue", "cancel" }, {
      prompt = "Dirty files: " .. #dirty,
    })
    :next(function(choice)
      if choice ~= "save and continue" then
        return Promise.reject({ error_class = "cancelled" })
      end
      for _, buf in ipairs(dirty) do
        local ok = pcall(vim.api.nvim_buf_call, buf, function()
          vim.cmd.write()
        end)
        if not ok or vim.bo[buf].modified or logical(buf) ~= disk_logical(buf) then
          return Promise.reject({ error_class = "write_failed" })
        end
      end
      return Promise.resolve(true)
    end)
end

return M
