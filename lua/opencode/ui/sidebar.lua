local Sidebar = {}
Sidebar.__index = Sidebar

local shared = { pane_id = nil, pane_pid = nil, runtime = nil }

---Runs one tmux command as argv and captures its result without shell interpolation.
---@param args string[]
---@param opts? table
---@return vim.SystemCompleted
local function tmux(args, opts)
  local command = { "tmux" }
  vim.list_extend(command, args)
  return vim.system(command, vim.tbl_extend("force", { text = true }, opts or {})):wait()
end

---Reads the pane ID and pane process ID that tmux currently associates with a target.
---Both values are needed because tmux pane IDs may be reused after the owned pane exits.
---@param pane_id string?
---@return table?
local function pane_details(pane_id)
  if not pane_id then
    return nil
  end
  local result = tmux({ "display-message", "-p", "-t", pane_id, "#{pane_id}\t#{pane_pid}" })
  if result.code ~= 0 then
    return nil
  end
  local id, pid = vim.trim(result.stdout or ""):match("^(%%[^%s]+)\t(%d+)$")
  return id and { pane_id = id, pane_pid = tonumber(pid) } or nil
end

---Stores one TUI process identity in the Runtime's private ownership manifest.
---Clearing it after verified pane removal prevents later shutdown from targeting an unrelated reused process ID.
---@param runtime table
---@param identity table?
local function update_manifest(runtime, identity)
  runtime.tui_identity = identity
  if runtime.manifest then
    runtime.manifest.tui = identity
    require("opencode.runtime.ownership").write(runtime.owner_manifest, runtime.manifest)
  end
end

---Forgets the shared pane and records its last known status on the Runtime that displayed it.
---@param status? string
local function clear_shared(status)
  local runtime = shared.runtime
  shared.pane_id, shared.pane_pid, shared.runtime = nil, nil, nil
  if runtime then
    runtime.tui_live = false
    runtime.tui_status = status or "stopped"
    update_manifest(runtime, nil)
  end
end

---Reports whether the stored pane still has the same tmux pane ID and process ID.
---A missing or reused pane is forgotten without sending a signal, so unrelated tmux panes are never treated as plugin-owned.
---@return boolean
local function shared_is_live()
  if not shared.pane_id then
    return false
  end
  local actual = pane_details(shared.pane_id)
  if actual and actual.pane_id == shared.pane_id and actual.pane_pid == shared.pane_pid then
    return true
  end
  clear_shared("dead")
  return false
end

---Kills the stored pane only after tmux confirms both its pane ID and process ID.
---The pane record and Runtime manifest are cleared even when the pane has already exited.
---@return boolean
local function kill_shared()
  if not shared.pane_id then
    return true
  end
  if not shared_is_live() then
    return true
  end
  local result = tmux({ "kill-pane", "-t", shared.pane_id })
  if result.code ~= 0 then
    return false
  end
  clear_shared("stopped")
  return true
end

---Creates a lazy handle for one Runtime; it does not start or display a TUI.
---@param runtime table
---@return table
function Sidebar.new(runtime)
  return setmetatable({ runtime = runtime }, Sidebar)
end

---Reports whether tmux commands can safely target the Neovim pane from this process.
---@return boolean
function Sidebar.available()
  return vim.fn.executable("tmux") == 1
    and vim.env.TMUX ~= nil
    and vim.env.TMUX ~= ""
    and vim.env.TMUX_PANE ~= nil
    and vim.env.TMUX_PANE ~= ""
end

---Shows this Runtime in the one detached, input-disabled tmux pane shared by all roots.
---A different root's verified pane is removed first, then `opencode attach` is passed as argv in the canonical root with Runtime auth.
---The detached split preserves the user's current pane and uses `$TMUX_PANE` as the explicit split target.
---@param runtime? table
---@return boolean
---@return string?
function Sidebar:show_root(runtime)
  runtime = runtime or self.runtime
  if runtime.interaction_locked then
    return false, "interaction_locked"
  end
  if shared_is_live() and shared.runtime == runtime then
    runtime.tui_live, runtime.tui_status = true, "live"
    return true
  end
  if shared.pane_id and not kill_shared() then
    return false, "tui_attach"
  end
  if not Sidebar.available() then
    return false, "tmux_required"
  end

  local percentage = require("opencode.config").opts.sidebar.width
  local format = "#{pane_id}\t#{pane_pid}"
  local binary = require("opencode.config").opts.runtime.binary
  local result = tmux({
    "split-window",
    "-h",
    "-d",
    "-p",
    tostring(percentage),
    "-t",
    vim.env.TMUX_PANE,
    "-P",
    "-F",
    format,
    "-e",
    "OPENCODE_SERVER_USERNAME=" .. runtime.username,
    "-e",
    "OPENCODE_SERVER_PASSWORD=" .. runtime.password,
    binary,
    "attach",
    runtime.client.url,
    "--dir",
    runtime.root,
  }, { cwd = runtime.root })
  if result.code ~= 0 then
    runtime.tui_live, runtime.tui_status = false, "error"
    return false, "tui_attach"
  end
  local pane_id, pane_pid = vim.trim(result.stdout or ""):match("^(%%[^%s]+)\t(%d+)$")
  pane_pid = tonumber(pane_pid)
  if not pane_id or not pane_pid then
    runtime.tui_live, runtime.tui_status = false, "error"
    return false, "tui_attach"
  end
  shared.pane_id, shared.pane_pid, shared.runtime = pane_id, pane_pid, runtime
  local disabled = tmux({ "select-pane", "-d", "-t", pane_id })
  local identity = require("opencode.runtime.ownership").identity(pane_pid)
  if disabled.code ~= 0 or not identity then
    kill_shared()
    runtime.tui_live, runtime.tui_status = false, "error"
    return false, disabled.code ~= 0 and "tui_attach" or "tui_identity"
  end
  runtime.tui_live, runtime.tui_status = true, "live"
  update_manifest(runtime, identity)
  return true
end

---Lazily shows this Runtime only while it remains the active root.
---@return boolean
---@return string?
function Sidebar:show()
  if require("opencode.runtime").current() ~= self.runtime then
    return false, "inactive_root"
  end
  return self:show_root(self.runtime)
end

---Reports whether this Runtime owns the currently live shared tmux pane.
---@return boolean
function Sidebar:is_visible()
  return shared.runtime == self.runtime and shared_is_live()
end

---Selects a transcript only while this Runtime's pane is reverified as live.
---Keeping the liveness check beside the endpoint call prevents Build and dead-pane paths from addressing TUI state.
---@param session_id string
---@return Promise<any>
function Sidebar:select_session(session_id)
  if not self:is_visible() then
    return require("opencode.promise").reject({ error_class = "tui_unavailable" })
  end
  return self.runtime.client:select_session(session_id)
end

---Returns the root whose plugin-owned pane is currently live.
---@return string?
function Sidebar.visible_root()
  return shared_is_live() and shared.runtime.root or nil
end

---Hides this Runtime by killing only its reverified plugin-owned pane.
---@return boolean
function Sidebar:hide()
  if shared.runtime ~= self.runtime then
    return true
  end
  return kill_shared()
end

---Lazily shows this Runtime, or hides it when its owned pane is already live.
function Sidebar:toggle()
  if self.runtime.interaction_locked then
    return
  end
  if self:is_visible() then
    self:hide()
  else
    local shown = self:show()
    if shown and self.runtime.selected_session_id then
      self:select_session(self.runtime.selected_session_id):catch(function()
        require("opencode.ui.notify").error("session_select")
      end)
    end
  end
end

---Lazily shows this Runtime and asks tmux to focus its reverified pane.
---The initial split remains detached; only this explicit manual action changes tmux focus.
function Sidebar:focus()
  if self.runtime.interaction_locked then
    return
  end
  local shown = self:show()
  if shown and self:is_visible() then
    if self.runtime.selected_session_id then
      self:select_session(self.runtime.selected_session_id):catch(function()
        require("opencode.ui.notify").error("session_select")
      end)
    end
    tmux({ "select-pane", "-t", shared.pane_id })
  end
end

---Marks a missing TUI without changing Server, SSE, Session, or Job state.
function Sidebar:dead()
  if shared.runtime == self.runtime then
    if shared_is_live() then
      kill_shared()
    end
  end
  self.runtime.tui_live, self.runtime.tui_status = false, "dead"
end

---Stops only this Runtime's reverified shared pane during owned shutdown.
function Sidebar:stop()
  self:hide()
end

return Sidebar
