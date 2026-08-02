local M = {}

local function remember(context, buf)
  local value = context.format({ buf = buf, rel = context.root })
  if value then
    context.referenced_buffers[buf] = true
  end
  return value
end

function M.this(context)
  if context.range then
    local from = { context.range.from[1] }
    local to = { context.range.to[1] }
    if context.range.kind == "bytes" then
      from[2], to[2] = context.range.from[2] + 1, context.range.to[2]
    elseif context.range.kind ~= "line" then
      from[2], to[2] = context.range.from[2] + 1, context.range.to[2] + 1
    end
    return context.format({ buf = context.buf, from = from, to = to, rel = context.root })
  end
  return context.format({ buf = context.buf, from = { context.cursor[1], context.cursor[2] + 1 }, rel = context.root })
end

function M.buffer(context)
  return remember(context, context.buf)
end

function M.buffers(context)
  local values = {}
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    local value = remember(context, info.bufnr)
    if value then
      table.insert(values, value)
    end
  end
  return #values > 0 and table.concat(values, ", ") or nil
end

function M.visible_text(context)
  local values = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local path = context.format({
      buf = buf,
      from = { vim.api.nvim_win_call(win, function()
        return vim.fn.line("w0")
      end) },
      to = { vim.api.nvim_win_call(win, function()
        return vim.fn.line("w$")
      end) },
      rel = context.root,
    })
    if path then
      context.referenced_buffers[buf] = true
      table.insert(values, path)
    end
  end
  return #values > 0 and table.concat(values, ", ") or nil
end

function M.diagnostics(context)
  local values = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(context.buf)) do
    local location =
      context.format({ buf = context.buf, from = { diagnostic.lnum + 1, diagnostic.col + 1 }, rel = context.root })
    table.insert(
      values,
      string.format("- %s: %s", location or "diagnostic", vim.trim(diagnostic.message:gsub("%s+", " ")))
    )
  end
  return #values > 0 and table.concat(values, "\n") or nil
end

function M.quickfix(context)
  local values = {}
  for _, entry in ipairs(vim.fn.getqflist()) do
    local location = entry.bufnr ~= 0
      and context.format({ buf = entry.bufnr, from = { entry.lnum, entry.col }, rel = context.root })
    if location then
      context.referenced_buffers[entry.bufnr] = true
      table.insert(values, location)
    elseif entry.text ~= "" then
      table.insert(values, entry.text)
    end
  end
  return #values > 0 and table.concat(values, ", ") or nil
end

function M.marks(context)
  local values = {}
  for _, mark in ipairs(vim.fn.getmarklist()) do
    if mark.mark:match("^'[A-Z]$") and mark.pos[1] ~= 0 and vim.api.nvim_buf_is_valid(mark.pos[1]) then
      local location = context.format({ buf = mark.pos[1], from = { mark.pos[2], mark.pos[3] }, rel = context.root })
      if location then
        context.referenced_buffers[mark.pos[1]] = true
        table.insert(values, location)
      end
    end
  end
  return #values > 0 and table.concat(values, ", ") or nil
end

return M
