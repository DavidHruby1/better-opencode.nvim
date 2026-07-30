local Sidebar = {}
Sidebar.__index = Sidebar

---Creates the owned attach terminal while preserving the source window.
---@param runtime table
---@return table?
---@return string?
function Sidebar.new(runtime)
  local source = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  local command = { "opencode", "attach", runtime.client.url, "--dir", runtime.root }
  local job
  vim.api.nvim_buf_call(buf, function()
    job = vim.fn.jobstart(command, {
      term = true,
      cwd = runtime.root,
      env = { OPENCODE_SERVER_USERNAME = runtime.username, OPENCODE_SERVER_PASSWORD = runtime.password },
    })
  end)
  if job <= 0 then
    vim.api.nvim_buf_delete(buf, { force = true })
    return nil, "tui_spawn"
  end
  vim.api.nvim_set_current_win(source)
  local self = setmetatable({ runtime = runtime, buf = buf, job = job, win = nil, source_win = source }, Sidebar)
  local group = vim.api.nvim_create_augroup("OpencodeSidebar" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TermEnter", "BufEnter", "ModeChanged" }, {
    group = group,
    buffer = buf,
    callback = function()
      if vim.api.nvim_get_current_buf() == buf and vim.fn.mode():sub(1, 1) == "t" then
        vim.cmd.stopinsert()
      end
    end,
  })
  for _, key in ipairs({ "i", "a", "I", "A", "o", "O" }) do
    vim.keymap.set("n", key, "<Nop>", { buffer = buf, nowait = true })
  end
  return self
end

---Shows the right sidebar without changing current source focus.
function Sidebar:show()
  if self.runtime.interaction_locked then
    return
  end
  local width = math.floor(vim.o.columns * require("opencode.config").opts.sidebar.width)
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_set_width(self.win, width)
    return
  end
  local source = vim.api.nvim_get_current_win()
  vim.cmd("botright vsplit")
  self.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.win, self.buf)
  vim.api.nvim_win_set_width(self.win, width)
  vim.api.nvim_set_current_win(source)
end

function Sidebar:hide()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  self.win = nil
end

function Sidebar:toggle()
  if self.runtime.interaction_locked then
    return
  end
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    self:hide()
  else
    self:show()
  end
end

function Sidebar:focus()
  if self.runtime.interaction_locked then
    return
  end
  self:show()
  if self.win then
    vim.api.nvim_set_current_win(self.win)
  end
end

function Sidebar:stop()
  self:hide()
  if self.job then
    vim.fn.jobstop(self.job)
  end
  self.job = nil
end

return Sidebar
