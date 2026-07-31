local Sidebar = {}
Sidebar.__index = Sidebar

local shared = { win = nil, active_root = nil }

local function valid_window(win)
  return win and vim.api.nvim_win_is_valid(win)
end

---Spawns an input-locked attach client in a Runtime-local terminal buffer.
local function spawn(runtime, buf, on_exit)
  buf = buf or vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local command =
    { require("opencode.config").opts.runtime.binary, "attach", runtime.client.url, "--dir", runtime.root }
  local source = vim.api.nvim_get_current_win()
  local job
  vim.api.nvim_buf_call(buf, function()
    job = vim.fn.jobstart(command, {
      term = true,
      cwd = runtime.root,
      env = { OPENCODE_SERVER_USERNAME = runtime.username, OPENCODE_SERVER_PASSWORD = runtime.password },
      on_exit = function(_, code)
        vim.schedule(function()
          on_exit(job, code)
        end)
      end,
    })
  end)
  vim.api.nvim_set_current_win(source)
  if job <= 0 then
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    return nil, "tui_spawn"
  end
  return { job = job, buf = buf }
end

---Installs the permanent Terminal-Normal guard and disables plugin-buffer input mappings.
local function install_lock(buf)
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
end

---Creates the one owned TUI client for a Runtime without creating a root-specific window.
---The terminal buffer remains Runtime-local; the shared sidebar window only displays the currently active root.
---@param runtime table
---@return table?
---@return string?
function Sidebar.new(runtime)
  local generation = runtime.tui_generation
  local result, err = spawn(runtime, nil, function(job)
    if runtime.tui_generation == generation and runtime.sidebar and runtime.sidebar.job == job then
      runtime:handle_tui_exit(generation)
    end
  end)
  if not result then
    return nil, err
  end
  install_lock(result.buf)
  local self = setmetatable({ runtime = runtime, buf = result.buf, job = result.job, win = shared.win }, Sidebar)
  return self
end

---Shows one Runtime's terminal in the shared sidebar without changing source focus or another Runtime's process.
---@param runtime? table
function Sidebar:show_root(runtime)
  runtime = runtime or self.runtime
  if runtime.interaction_locked or not runtime.sidebar.buf or not vim.api.nvim_buf_is_valid(runtime.sidebar.buf) then
    return
  end
  shared.active_root = runtime.root
  local width = math.floor(vim.o.columns * require("opencode.config").opts.sidebar.width)
  local source = vim.api.nvim_get_current_win()
  if not valid_window(shared.win) then
    vim.cmd("botright vsplit")
    shared.win = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_win_set_buf(shared.win, runtime.sidebar.buf)
  vim.api.nvim_win_set_width(shared.win, width)
  vim.api.nvim_set_current_win(source)
  self.win = shared.win
end

function Sidebar:show()
  local active = require("opencode.runtime").current()
  if active == self.runtime then
    self:show_root(self.runtime)
  end
end

---Reports visibility for this Runtime only, excluding a stale window reference left after switching roots.
---@return boolean
function Sidebar:is_visible()
  return shared.active_root == self.runtime.root
    and valid_window(shared.win)
    and vim.api.nvim_win_get_buf(shared.win) == self.buf
end

function Sidebar:hide()
  if valid_window(shared.win) then
    vim.api.nvim_win_close(shared.win, true)
  end
  shared.win = nil
  self.win = nil
end

function Sidebar:toggle()
  if self.runtime.interaction_locked then
    return
  end
  if valid_window(shared.win) and shared.active_root == self.runtime.root then
    self:hide()
  else
    self:show_root(self.runtime)
  end
end

function Sidebar:focus()
  if self.runtime.interaction_locked then
    return
  end
  self:show_root(self.runtime)
  if valid_window(shared.win) then
    vim.api.nvim_set_current_win(shared.win)
  end
end

---Marks a TUI process dead and removes only its terminal buffer while preserving the Server and Job state.
---The next recovery attach reuses the same Runtime credentials and selected Session.
function Sidebar:dead()
  if self.job then
    local ownership = require("opencode.runtime.ownership")
    local verified, running = ownership.verified(self.runtime.tui_identity)
    if verified and running then
      vim.fn.jobstop(self.job)
    end
  end
  if valid_window(shared.win) and vim.api.nvim_win_get_buf(shared.win) == self.buf then
    vim.api.nvim_win_close(shared.win, true)
    shared.win = nil
  end
  if vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_delete(self.buf, { force = true })
  end
  self.job, self.buf = nil, nil
end

---Attaches a replacement TUI to the same owned Server and restores the selected transcript after process readiness.
---A failed attach leaves the existing Runtime and Jobs intact so the user can retry explicitly.
---@return Promise<table>
function Sidebar:recover()
  local Promise = require("opencode.promise")
  local was_visible = valid_window(shared.win) and shared.active_root == self.runtime.root
  self:dead()
  self.runtime.tui_generation = self.runtime.tui_generation + 1
  local generation = self.runtime.tui_generation
  local result, err = spawn(self.runtime, nil, function(job)
    if self.runtime.tui_generation == generation and self.job == job then
      self.runtime:handle_tui_exit(generation)
    end
  end)
  if not result then
    self.runtime.tui_recovery_error = err
    require("opencode.ui.notify").error("tui_attach")
    return Promise.reject({ error_class = err })
  end
  install_lock(result.buf)
  self.buf, self.job = result.buf, result.job
  self.runtime.tui_identity = require("opencode.runtime.ownership").identity(vim.fn.jobpid(self.job))
  if not self.runtime.tui_identity then
    self:dead()
    return Promise.reject({ error_class = "tui_identity" })
  end
  self.runtime.manifest.tui = self.runtime.tui_identity
  require("opencode.runtime.ownership").write(self.runtime.owner_manifest, self.runtime.manifest)
  local selected = self.runtime.selected_session_id
  local selected_result = selected and self.runtime.client:select_session(selected) or Promise.resolve(nil)
  return selected_result
    :catch(function()
      return nil
    end)
    :next(function()
      if was_visible and not self.runtime.interaction_locked then
        self:show_root(self.runtime)
      end
      self.runtime.tui_recovery_error = nil
      return self.runtime
    end)
end

function Sidebar:stop()
  if valid_window(shared.win) and shared.active_root == self.runtime.root then
    self:hide()
  end
  if self.job then
    local ownership = require("opencode.runtime.ownership")
    local verified, running = ownership.verified(self.runtime.tui_identity)
    if verified and running then
      vim.fn.jobstop(self.job)
    end
  end
  self.job = nil
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_delete(self.buf, { force = true })
  end
  self.buf = nil
end

return Sidebar
